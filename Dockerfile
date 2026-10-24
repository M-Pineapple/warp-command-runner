# Linux container build of the stdio MCP server, for registries such as Glama
# that start the server in a container to check it. The full tool list is
# advertised; tools that drive Warp or other macOS apps answer with a clear
# "needs macOS" error. Remote --http mode is macOS only.
#
#   docker build -t warp-command-runner .
#   docker run -i --rm warp-command-runner

FROM swift:6.1-jammy AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product warp-command-runner \
    && cp "$(swift build -c release --show-bin-path)/warp-command-runner" /usr/local/bin/

FROM swift:6.1-jammy-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash mcp
COPY --from=build /usr/local/bin/warp-command-runner /usr/local/bin/warp-command-runner
USER mcp
WORKDIR /home/mcp
ENTRYPOINT ["warp-command-runner"]
