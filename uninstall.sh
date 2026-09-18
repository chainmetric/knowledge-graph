#!/usr/bin/env bash
# Stop and remove the knowledge-graph HTTP service. The client config is not
# reverted here — restore a ~/.claude.json.bak.* written by install.sh if you
# want the stdio server back.
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { printf 'run as your own user, not root\n' >&2; exit 1; }

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

systemctl --user disable --now knowledge-graph.service 2>/dev/null || true
rm -f "$UNIT_DIR/knowledge-graph.service"
systemctl --user daemon-reload || true

printf 'stopped and removed the unit.\n'
printf 'kept: ~/.config/knowledge-graph/server.env (token + paths).\n'
printf 'not reverted: ~/.claude.json — restore a .bak.* if you want the stdio server back.\n'
