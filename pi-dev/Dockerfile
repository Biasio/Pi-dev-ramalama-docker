# pi-dev/Dockerfile — image for the pi-agent service (compose.yaml).
# Builds a Node.js sandbox with pi-coding-agent installed globally, plus
# the base toolchain it needs to actually act on a codebase (git, curl,
# python3, build tools, ripgrep, jq, fd, sqlite3). The resulting image is
# tagged pi-sandbox-image and runs as a long-lived container (entrypoint
# is "sleep infinity" in compose.yaml) that pi-ramalama execs into for both
# the TUI and RPC flows.
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl python3 python3-pip ripgrep jq fd-find sqlite3 build-essential cmake gcc g++ make ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd

ARG PI_CODING_AGENT_VERSION=latest

RUN npm install -g --ignore-scripts \
    @earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION}

WORKDIR /workspace
