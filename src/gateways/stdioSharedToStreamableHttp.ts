/**
 * stdio → Streamable HTTP with one shared stdio child per process.
 *
 * - stdio initializes once; HTTP session ids are accepted but not required for routing.
 * - Duplicate GET replaces the active SSE stream (ferry-style).
 * - Notifications are queued with Last-Event-ID replay (256 events).
 * - Outbound stdio writes are limited by SUPERGATEWAY_SHARED_MAX_INFLIGHT (default 1).
 */

import cors, { type CorsOptions } from 'cors'
import express from 'express'
import { spawn, type ChildProcess } from 'child_process'
import { randomUUID } from 'node:crypto'
import { Logger } from '../types.js'
import { onSignals } from '../lib/onSignals.js'
import { serializeCorsOrigin } from '../lib/serializeCorsOrigin.js'

const HEADER_MCP_SESSION_ID = 'mcp-session-id'
const HEADER_LAST_EVENT_ID = 'last-event-id'
const SSE_REPLAY_HISTORY_LIMIT = 256

export interface StdioSharedToStreamableHttpArgs {
  stdioCmd: string
  port: number
  streamableHttpPath: string
  logger: Logger
  corsOrigin: CorsOptions['origin']
  healthEndpoints: string[]
  headers: Record<string, string>
}

type JsonRpcId = string | number | null

interface JsonRpcMessage {
  jsonrpc?: string
  id?: JsonRpcId
  method?: string
  params?: unknown
  result?: {
    protocolVersion?: string
    [key: string]: unknown
  }
  error?: unknown
}

type MessageKind =
  | { kind: 'notification' }
  | { kind: 'request'; method: string; idKey: string }
  | { kind: 'response' }

interface QueuedSseMessage {
  eventId: string
  eventSequence: number
  event: string | null
  data: string
}

interface GetStream {
  streamId: number
  replayMessages: QueuedSseMessage[]
  attach: (res: express.Response) => void
  res: express.Response | null
}

interface HttpPending {
  kind: 'http' | 'sse'
  resolve: (message: JsonRpcMessage) => void
  reject: (error: Error) => void
}

interface HttpError extends Error {
  status?: number
}

const setResponseHeaders = ({
  res,
  headers,
}: {
  res: express.Response
  headers: Record<string, string>
}) =>
  Object.entries(headers).forEach(([key, value]) => {
    res.setHeader(key, value)
  })

function parseMaxInflight(): number {
  const raw = process.env.SUPERGATEWAY_SHARED_MAX_INFLIGHT
  if (raw === undefined || raw === '') {
    return 1
  }
  const parsed = Number.parseInt(raw, 10)
  return Number.isFinite(parsed) && parsed >= 1 ? parsed : 1
}

function jsonrpcIdKey(id: JsonRpcId): string {
  return JSON.stringify(id)
}

function requestId(message: JsonRpcMessage): JsonRpcId | undefined {
  if (!message || typeof message !== 'object' || !('method' in message)) {
    return undefined
  }
  return message.id
}

function responseId(message: JsonRpcMessage): JsonRpcId | undefined {
  if (!message || typeof message !== 'object' || message.method !== undefined) {
    return undefined
  }
  return message.id
}

function extractProtocolVersion(
  message: JsonRpcMessage,
  expectedId: JsonRpcId | undefined,
): string | undefined {
  if (!message || typeof message !== 'object') {
    return undefined
  }
  if (expectedId !== undefined && message.id !== expectedId) {
    return undefined
  }
  return message.result?.protocolVersion
}

function classifyMessage(message: JsonRpcMessage): MessageKind {
  if (!message || typeof message !== 'object' || Array.isArray(message)) {
    throw new Error('JSON-RPC message must be an object')
  }
  if (typeof message.method === 'string') {
    if (message.id === undefined) {
      return { kind: 'notification' }
    }
    return {
      kind: 'request',
      method: message.method,
      idKey: jsonrpcIdKey(message.id),
    }
  }
  if (message.id !== undefined) {
    jsonrpcIdKey(message.id)
    return { kind: 'response' }
  }
  throw new Error('JSON-RPC object must contain either a method or an id')
}

function formatSseEventId(sessionId: string, sequence: number): string {
  return `${sessionId}:${sequence}`
}

function parseSseEventId(
  value: string,
): { sessionId: string; sequence: number } | undefined {
  const idx = value.lastIndexOf(':')
  if (idx <= 0) {
    return undefined
  }
  const sessionId = value.slice(0, idx)
  const sequence = Number.parseInt(value.slice(idx + 1), 10)
  if (!sessionId || Number.isNaN(sequence)) {
    return undefined
  }
  return { sessionId, sequence }
}

function writeSseEvent(
  res: express.Response,
  { eventId, event, data }: QueuedSseMessage,
): void {
  if (eventId) {
    res.write(`id: ${eventId}\n`)
  }
  if (event) {
    res.write(`event: ${event}\n`)
  }
  res.write(`data: ${data}\n\n`)
}

class SharedStdioBridge {
  private stdioCmd: string
  private logger: Logger
  private maxInflight: number
  private inflightCount = 0
  private inflightWaiters: Array<() => void> = []
  private child: ChildProcess | null = null
  private buffer = ''
  private pendingRequests = new Map<string, HttpPending>()
  private protocolVersion: string | null = null
  private initResult: JsonRpcMessage | null = null
  private canonicalSessionId = `shared-session-${randomUUID()}`
  private activeGetStream: {
    streamId: number
    res: express.Response
  } | null = null
  private replayHistory: QueuedSseMessage[] = []
  private queuedMessages: QueuedSseMessage[] = []
  private nextEventSequence = 1
  private nextGetStreamId = 1

  constructor(
    stdioCmd: string,
    logger: Logger,
    { maxInflight = parseMaxInflight() }: { maxInflight?: number } = {},
  ) {
    this.stdioCmd = stdioCmd
    this.logger = logger
    this.maxInflight = maxInflight
    this.startChild()
  }

  private async acquireInflightSlot(): Promise<void> {
    if (this.inflightCount < this.maxInflight) {
      this.inflightCount += 1
      return
    }
    await new Promise<void>((resolve) => {
      this.inflightWaiters.push(resolve)
    })
    this.inflightCount += 1
  }

  private releaseInflightSlot(): void {
    this.inflightCount = Math.max(0, this.inflightCount - 1)
    const next = this.inflightWaiters.shift()
    if (next) {
      next()
    }
  }

  private resetInflightSlots(): void {
    this.inflightCount = 0
    this.inflightWaiters.length = 0
  }

  private startChild(): void {
    this.child = spawn(this.stdioCmd, { shell: true })
    this.child.on('exit', (code, signal) => {
      this.logger.error(
        `Shared stdio child exited: code=${code}, signal=${signal}`,
      )
      this.failPending(new Error('stdio backend exited'))
      this.activeGetStream = null
      this.child = null
    })
    this.child.stdout?.on('data', (chunk: Buffer) => this.onStdout(chunk))
    this.child.stderr?.on('data', (chunk: Buffer) => {
      this.logger.error(`Child stderr: ${chunk.toString('utf8')}`)
    })
  }

  private ensureChild(): void {
    if (!this.child) {
      this.logger.info('Restarting shared stdio child')
      this.startChild()
    }
  }

  private failPending(error: Error): void {
    for (const pending of this.pendingRequests.values()) {
      if (pending.kind === 'http') {
        pending.reject(error)
      }
    }
    this.pendingRequests.clear()
    this.resetInflightSlots()
  }

  private onStdout(chunk: Buffer): void {
    this.buffer += chunk.toString('utf8')
    const lines = this.buffer.split(/\r?\n/)
    this.buffer = lines.pop() ?? ''
    for (const line of lines) {
      if (!line.trim()) {
        continue
      }
      let message: JsonRpcMessage
      try {
        message = JSON.parse(line) as JsonRpcMessage
      } catch {
        this.logger.error(`Child non-JSON: ${line}`)
        continue
      }
      this.logger.info('Child → HTTP:', line)
      void this.handleBackendMessage(message)
    }
  }

  private async handleBackendMessage(message: JsonRpcMessage): Promise<void> {
    const id = responseId(message)
    if (id !== undefined) {
      const key = jsonrpcIdKey(id)
      const pending = this.pendingRequests.get(key)
      if (pending) {
        this.pendingRequests.delete(key)
        if (pending.kind === 'http') {
          pending.resolve(message)
          return
        }
        await this.queueBackendMessage(message)
        return
      }
    }
    await this.queueBackendMessage(message)
  }

  private writeToChild(message: JsonRpcMessage): void {
    this.ensureChild()
    const line = `${JSON.stringify(message)}\n`
    this.logger.info(`HTTP → Child: ${line.trim()}`)
    this.child?.stdin?.write(line)
  }

  async sendRequest(
    message: JsonRpcMessage,
    { viaSse = false }: { viaSse?: boolean } = {},
  ): Promise<JsonRpcMessage> {
    const id = requestId(message)
    if (id === undefined) {
      throw new Error('request is missing a JSON-RPC id')
    }
    const idKey = jsonrpcIdKey(id)
    if (this.pendingRequests.has(idKey)) {
      const error = httpError(409, 'request id is already outstanding')
      throw error
    }

    await this.acquireInflightSlot()

    return new Promise<JsonRpcMessage>((resolve, reject) => {
      const release = () => this.releaseInflightSlot()
      this.pendingRequests.set(idKey, {
        kind: viaSse ? 'sse' : 'http',
        resolve: (response) => {
          release()
          resolve(response)
        },
        reject: (error) => {
          release()
          reject(error)
        },
      })
      try {
        this.writeToChild(message)
      } catch (error) {
        this.pendingRequests.delete(idKey)
        release()
        reject(error instanceof Error ? error : new Error(String(error)))
      }
    })
  }

  async sendOneway(message: JsonRpcMessage): Promise<void> {
    await this.acquireInflightSlot()
    try {
      this.writeToChild(message)
    } finally {
      this.releaseInflightSlot()
    }
  }

  async initializeOnce(message: JsonRpcMessage): Promise<JsonRpcMessage> {
    if (this.initResult) {
      return this.initResult
    }
    const id = requestId(message)
    const response = await this.sendRequest(message)
    const version = extractProtocolVersion(response, id)
    if (!version) {
      throw new Error('initialize response missing result.protocolVersion')
    }
    this.protocolVersion = version
    this.initResult = response
    return response
  }

  private async queueBackendMessage(message: JsonRpcMessage): Promise<void> {
    await this.queueSseMessage(null, JSON.stringify(message))
  }

  private async queueSseMessage(
    event: string | null,
    data: string,
  ): Promise<void> {
    const eventSequence = this.nextEventSequence++
    const queued: QueuedSseMessage = {
      eventId: formatSseEventId(this.canonicalSessionId, eventSequence),
      eventSequence,
      event,
      data,
    }

    this.replayHistory.push(queued)
    while (this.replayHistory.length > SSE_REPLAY_HISTORY_LIMIT) {
      this.replayHistory.shift()
    }

    const active = this.activeGetStream
    if (active && !active.res.writableEnded) {
      try {
        writeSseEvent(active.res, queued)
        return
      } catch (error) {
        this.logger.error(`Failed writing to active GET stream: ${error}`)
      }
    }

    this.queuedMessages.push(queued)
  }

  closeActiveGetStream(): void {
    if (!this.activeGetStream) {
      return
    }
    const { res, streamId } = this.activeGetStream
    if (!res.writableEnded) {
      res.end()
    }
    if (this.activeGetStream?.streamId === streamId) {
      this.activeGetStream = null
    }
  }

  openGetStream(replayAfterSequence?: number): GetStream {
    this.closeActiveGetStream()

    const streamId = this.nextGetStreamId++
    const resRef: { current: express.Response | null } = { current: null }

    let replayMessages: QueuedSseMessage[]
    if (replayAfterSequence !== undefined) {
      replayMessages = this.replayHistory.filter(
        (message) => message.eventSequence > replayAfterSequence,
      )
      if (replayMessages.length > 0) {
        const replayed = new Set(
          replayMessages.map((message) => message.eventSequence),
        )
        this.queuedMessages = this.queuedMessages.filter(
          (message) => !replayed.has(message.eventSequence),
        )
      }
    } else {
      replayMessages = this.queuedMessages.splice(0)
    }

    return {
      streamId,
      replayMessages,
      attach(res: express.Response) {
        resRef.current = res
      },
      get res() {
        return resRef.current
      },
    }
  }

  attachGetStream(stream: GetStream, res: express.Response): void {
    stream.attach(res)
    this.activeGetStream = { streamId: stream.streamId, res }

    res.on('close', () => {
      if (this.activeGetStream?.streamId === stream.streamId) {
        this.activeGetStream = null
      }
    })

    for (const message of stream.replayMessages) {
      writeSseEvent(res, message)
    }
  }

  get sessionId(): string {
    return this.canonicalSessionId
  }
}

function httpError(status: number, message: string): HttpError {
  const error = new Error(message) as HttpError
  error.status = status
  return error
}

// Express res.json()/res.send() append "; charset=utf-8" even when content-type is
// set to bare application/json. Envoy AI Gateway mcpproxy mis-parses that as SSE
// and drops tools/list (envoyproxy/ai-gateway#2306).
function sendJsonResponse(
  res: express.Response,
  status: number,
  body: unknown,
): void {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(payload),
  })
  res.end(payload)
}

export async function stdioSharedToStreamableHttp(
  args: StdioSharedToStreamableHttpArgs,
): Promise<void> {
  const {
    stdioCmd,
    port,
    streamableHttpPath,
    logger,
    corsOrigin: corsOriginValue,
    healthEndpoints,
    headers,
  } = args

  const maxInflight = parseMaxInflight()
  logger.info(
    '  - mode: shared (one stdio child per process, accept-any session)',
  )
  logger.info(`  - maxInflight: ${maxInflight}`)
  logger.info(`  - port: ${port}`)
  logger.info(`  - stdio: ${stdioCmd}`)
  logger.info(`  - streamableHttpPath: ${streamableHttpPath}`)
  logger.info(
    `  - CORS: ${corsOriginValue ? `enabled (${serializeCorsOrigin({ corsOrigin: corsOriginValue })})` : 'disabled'}`,
  )
  logger.info(
    `  - Health endpoints: ${healthEndpoints.length ? healthEndpoints.join(', ') : '(none)'}`,
  )

  onSignals({ logger })

  const bridge = new SharedStdioBridge(stdioCmd, logger, { maxInflight })
  const app = express()
  app.use(express.json())

  if (corsOriginValue) {
    app.use(
      cors({
        origin: corsOriginValue,
        exposedHeaders: ['Mcp-Session-Id', 'MCP-Session-Id'],
      }),
    )
  }

  for (const ep of healthEndpoints) {
    app.get(ep, (_req, res) => {
      setResponseHeaders({ res, headers })
      res.send('ok')
    })
  }

  app.post(streamableHttpPath, async (req, res) => {
    setResponseHeaders({ res, headers })

    try {
      const message = req.body as JsonRpcMessage
      if (Array.isArray(message)) {
        sendJsonResponse(res, 400, {
          jsonrpc: '2.0',
          error: {
            code: -32600,
            message: 'batch JSON-RPC messages are not supported',
          },
          id: null,
        })
        return
      }

      const kind = classifyMessage(message)

      if (kind.kind === 'request' && kind.method === 'initialize') {
        const response = await bridge.initializeOnce(message)
        res.setHeader(HEADER_MCP_SESSION_ID, bridge.sessionId)
        sendJsonResponse(res, 200, response)
        return
      }

      switch (kind.kind) {
        case 'request': {
          if (kind.method === 'initialize') {
            throw httpError(
              400,
              'initialize cannot be sent on an existing session',
            )
          }
          const response = await bridge.sendRequest(message)
          sendJsonResponse(res, 200, response)
          break
        }
        case 'notification':
        case 'response':
          await bridge.sendOneway(message)
          res.status(202).end()
          break
        default:
          throw httpError(400, 'unsupported JSON-RPC message')
      }
    } catch (error) {
      const httpErr = error as HttpError
      const status = httpErr.status ?? 502
      if (status === 409) {
        res.status(409).send(httpErr.message)
        return
      }
      if (status >= 400 && status < 500) {
        res.status(status).send(httpErr.message)
        return
      }
      logger.error('POST /mcp failed:', error)
      res.status(502).send(`backend error: ${httpErr.message}`)
    }
  })

  app.get(streamableHttpPath, (req, res) => {
    setResponseHeaders({ res, headers })

    try {
      let replayAfterSequence: number | undefined
      const lastEventId = req.headers[HEADER_LAST_EVENT_ID]
      if (lastEventId) {
        const parsed = parseSseEventId(String(lastEventId))
        if (!parsed) {
          res.status(400).send('invalid Last-Event-ID header')
          return
        }
        replayAfterSequence = parsed.sequence
      }

      const stream = bridge.openGetStream(replayAfterSequence)
      res.setHeader('content-type', 'text/event-stream')
      res.setHeader('cache-control', 'no-cache, no-transform')
      res.setHeader('connection', 'keep-alive')
      res.setHeader(HEADER_MCP_SESSION_ID, bridge.sessionId)
      res.flushHeaders?.()

      bridge.attachGetStream(stream, res)
      logger.info(`GET stream opened (stream ${stream.streamId})`)
    } catch (error) {
      const httpErr = error as HttpError
      const status = httpErr.status ?? 502
      logger.error('GET /mcp failed:', error)
      if (!res.headersSent) {
        res.status(status).send(httpErr.message)
      }
    }
  })

  app.delete(streamableHttpPath, (req, res) => {
    setResponseHeaders({ res, headers })
    bridge.closeActiveGetStream()
    res.status(204).end()
  })

  app.listen(port, () => {
    logger.info(`Listening on port ${port}`)
    logger.info(
      `StreamableHttp endpoint: http://localhost:${port}${streamableHttpPath}`,
    )
  })
}
