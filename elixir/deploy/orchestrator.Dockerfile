FROM elixir:1.19-slim AS build

ENV MIX_ENV=prod
WORKDIR /app/elixir

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

COPY elixir/mix.exs elixir/mix.lock ./
RUN mix local.hex --force \
  && mix local.rebar --force \
  && mix deps.get --only prod

COPY elixir ./
RUN mix deps.compile \
  && mix compile \
  && mix escript.build

FROM elixir:1.19-slim

ENV HOME=/root \
    MIX_ENV=prod \
    SYMPHONY_WORKSPACE_ROOT=/var/lib/symphony/workspaces

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    git \
    nodejs \
    npm \
    openssh-client \
    ripgrep \
  && npm install --global @openai/codex \
  && mix local.hex --force \
  && mix local.rebar --force \
  && install -d -m 700 /root/.codex \
  && install -d -m 755 /var/lib/symphony/workspaces /var/log/symphony \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app/elixir
COPY --from=build /app/elixir /app/elixir
COPY elixir/deploy/entrypoint.sh /usr/local/bin/symphony-orchestrator
RUN chmod 755 /usr/local/bin/symphony-orchestrator

ENTRYPOINT ["/usr/local/bin/symphony-orchestrator"]
CMD ["./bin/symphony", "--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--logs-root", "/var/log/symphony", "--port", "4000", "/app/elixir/WORKFLOW.md"]
