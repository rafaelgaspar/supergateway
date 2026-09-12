---
name: rafaelgaspar-fork
description: >-
  Work with the rafaelgaspar/supergateway fork of supercorp-ai/supergateway — stacked feat branches,
  rafaelgaspar integration pointer, GHCR publish, upstream tag rebuilds.
  Use when changing Supergateway upstream-bound code, fork branches, stack order,
  or ghcr.io/rafaelgaspar/supergateway images.
disable-model-invocation: true
---

# Supergateway fork (`rafaelgaspar/supergateway`)

Upstream: [supercorp-ai/supergateway](https://github.com/supercorp-ai/supergateway). Fork:
[rafaelgaspar/supergateway](https://github.com/rafaelgaspar/supergateway). Ships
**`ghcr.io/rafaelgaspar/supergateway`** from integration branch **`rafaelgaspar`**.

The fork image is a **generic base** (Node 26 on Debian forkly, built supergateway, upstream-style
`ENTRYPOINT ["supergateway"]`). Consumers may wrap it with their own ENTRYPOINT (e.g. `tini` and
`--shared` for MCP gateway images).

Each `feat/*` branch carries **exactly one commit** on its parent.

Validate: `./.github/scripts/rebuild-rafaelgaspar.sh --dry-run v3.4.3`

## Upstream tag bump

```sh
./.github/scripts/rebuild-rafaelgaspar.sh --squash --push vX.Y.Z
```
