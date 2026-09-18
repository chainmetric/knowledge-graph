#!/usr/bin/env bash
# Rebuild the knowledge-graph server from the current source and restart the
# service. Run this after pulling new code. Mirrors the runner's update flow:
# rebuild, restart, confirm it came back.
#
# The token, port, and vault paths live in the unit's EnvironmentFile and are
# untouched here, so the client config keeps working across an update.
set -euo pipefail

die() { printf 'knowledge-graph update: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your own user, not root — systemctl --user targets the user manager"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf 'rebuilding dist/ ...\n'
( cd "$ROOT" && npm install --no-audit --no-fund >/dev/null && npm run build >/dev/null ) \
  || die "build failed — run 'npm run build' in $ROOT to see why"
[ -f "$ROOT/dist/mcp/index.js" ] || die "build produced no dist/mcp/index.js"

systemctl --user restart knowledge-graph.service
systemctl --user is-active --quiet knowledge-graph.service \
  || die "the unit did not come back — 'systemctl --user status knowledge-graph' says why"

printf 'rebuilt and restarted. this machine now serves the current build.\n'
