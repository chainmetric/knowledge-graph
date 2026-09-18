#!/usr/bin/env bash
# Provision the knowledge-graph MCP server as a persistent localhost HTTP
# service and point this machine's Claude config at it.
#
# One shared server replaces the stdio server Claude spawned once per session,
# so N sessions stop costing N copies of the runtime and there is no per-client
# child left to orphan. Re-runnable: an existing token is reused and only what
# changed is rewritten.
#
# This is operator tooling and is deliberately separate from the runner
# installer. A customer-hosted runner has no operator vault to serve, and its
# agents reach the platform's own HTTP MCP, not this one — so shipping this
# through the runner install would put a dead service on customer machines.
set -euo pipefail

die() { printf 'knowledge-graph install: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your own user, not root — systemctl --user targets the user manager, and under sudo that is root's"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="$(command -v node)" || die "node not found on PATH"
command -v npm >/dev/null || die "npm not found on PATH"
command -v openssl >/dev/null || die "openssl not found on PATH"

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/knowledge-graph"
ENV_FILE="$CONF_DIR/server.env"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/knowledge-graph.service"
CLAUDE_JSON="$HOME/.claude.json"

HOST="127.0.0.1"
PORT="${KG_PORT:-7690}"

# Vault + data dir: an explicit environment override wins; otherwise inherit
# them from the stdio entry this install is replacing, so nothing has to be
# retyped and the same DB keeps being served.
VAULT="${KG_VAULT_PATH:-}"
DATA="${KG_DATA_DIR:-}"
if { [ -z "$VAULT" ] || [ -z "$DATA" ]; } && [ -f "$CLAUDE_JSON" ]; then
  read -r VAULT DATA < <(node -e '
    const fs = require("fs");
    let d = {}; try { d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {}
    const e = (((d.mcpServers || {}).knowledge || {}).env) || {};
    process.stdout.write(
      (process.env.KG_VAULT_PATH || e.KG_VAULT_PATH || "") + " " +
      (process.env.KG_DATA_DIR   || e.KG_DATA_DIR   || "") + "\n");
  ' "$CLAUDE_JSON") || true
fi
[ -n "$VAULT" ] || die "KG_VAULT_PATH not set and none found in $CLAUDE_JSON — export KG_VAULT_PATH and re-run"
[ -n "$DATA" ]  || die "KG_DATA_DIR not set and none found in $CLAUDE_JSON — export KG_DATA_DIR and re-run"

printf 'building dist/ ...\n'
( cd "$ROOT" && npm install --no-audit --no-fund >/dev/null && npm run build >/dev/null ) \
  || die "build failed — run 'npm run build' in $ROOT to see why"
[ -f "$ROOT/dist/mcp/index.js" ] || die "build produced no dist/mcp/index.js"

# Token: minted once, reused on every later run so a re-install does not
# invalidate the client entry it is about to write.
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
TOKEN=""
[ -f "$ENV_FILE" ] && TOKEN="$(sed -n 's/^KG_TOKEN=//p' "$ENV_FILE" | head -1)"
[ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 32)"

umask 077
cat > "$ENV_FILE" <<EOF
KG_TRANSPORT=http
KG_PORT=$PORT
KG_TOKEN=$TOKEN
KG_VAULT_PATH=$VAULT
KG_DATA_DIR=$DATA
EOF
chmod 600 "$ENV_FILE"

mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<EOF
[Unit]
Description=knowledge-graph MCP server (localhost HTTP)
After=default.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$NODE $ROOT/dist/mcp/index.js
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

# Linger so the unit runs on a headless box with no login session — the same
# reason the runner enables it.
loginctl enable-linger "$USER" >/dev/null 2>&1 || true
systemctl --user daemon-reload
systemctl --user enable --now knowledge-graph.service

ok=""
for _ in $(seq 1 30); do
  if curl -fsS -m 2 \
       -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
       -H "Accept: application/json, text/event-stream" \
       -X POST "http://$HOST:$PORT/mcp" \
       -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install","version":"0"}}}' \
       2>/dev/null | grep -q '"serverInfo"'; then ok=1; break; fi
  sleep 0.5
done
[ -n "$ok" ] || die "server did not answer on http://$HOST:$PORT/mcp — 'systemctl --user status knowledge-graph' says why"
printf 'server healthy on http://%s:%s/mcp\n' "$HOST" "$PORT"

# Point the client at the endpoint. Backed up first, written atomically, and
# only the one entry is touched. Existing Claude sessions read this at startup,
# so they keep their current server until relaunched — the switch is not
# disruptive.
if [ -f "$CLAUDE_JSON" ]; then
  BK="$CLAUDE_JSON.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$CLAUDE_JSON" "$BK"
  node -e '
    const fs = require("fs");
    const [p, url, token] = process.argv.slice(1);
    const d = JSON.parse(fs.readFileSync(p, "utf8"));
    d.mcpServers = d.mcpServers || {};
    d.mcpServers.knowledge = { type: "http", url, headers: { Authorization: "Bearer " + token } };
    const tmp = p + ".tmp." + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(d, null, 2));
    fs.renameSync(tmp, p);
  ' "$CLAUDE_JSON" "http://$HOST:$PORT/mcp" "$TOKEN"
  printf "pointed the 'knowledge' server in %s at the HTTP endpoint (backup: %s)\n" "$CLAUDE_JSON" "$BK"
  printf 'existing sessions keep their current server until relaunched.\n'
else
  printf 'no %s found — add a knowledge server manually:\n' "$CLAUDE_JSON"
  printf '  "knowledge": {"type":"http","url":"http://%s:%s/mcp","headers":{"Authorization":"Bearer %s"}}\n' "$HOST" "$PORT" "$TOKEN"
fi
printf 'done.\n'
