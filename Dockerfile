# syntax=docker/dockerfile:1
# rafaelgaspar/supergateway — Node 26 on Debian forkly, built from fork source.
# Generic base image: no deployment-specific ENTRYPOINT (--shared, tini).
FROM debian:forky-slim@sha256:91b0aaebf7a1ccacfe7a9cbff6ab2d6be7d9b3b6cf1dfcf44b25f9095c0e0464

ENV DEBIAN_FRONTEND=noninteractive
ENV HUSKY=0

RUN apt-get update \
  && apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_26.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
  && printf '%s\n' \
      'Package: nodejs' \
      'Pin: origin deb.nodesource.com' \
      'Pin-Priority: 1001' \
    > /etc/apt/preferences.d/nodesource \
  && apt-get update \
  && apt-get install -y --no-install-recommends nodejs \
  && node --version \
  && npm --version \
  && groupadd --gid 1000 node \
  && useradd --uid 1000 --gid node --shell /bin/bash --create-home node \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build && npm install -g .

ENTRYPOINT ["supergateway"]
CMD ["--help"]
