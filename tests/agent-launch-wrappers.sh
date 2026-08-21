#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

raw="$TMPROOT/codex-wrapper.sh"
awk '
    /^    cat >> "\$wrapper_tmp" <<.CODEX_WRAPPER./ { capture=1; next }
    /^CODEX_WRAPPER$/ { if (capture) exit }
    capture { print }
' "$BOXA_DIR/scripts/setup-claude.sh" > "$raw"

if [ ! -s "$raw" ]; then
    printf 'FAIL  could not extract Codex launch wrapper\n'
    exit 1
fi

mkdir -p "$TMPROOT/bin" "$TMPROOT/share/mcp"
cat > "$TMPROOT/bin/python3" <<'PYTHON_MOCK'
#!/bin/bash
printf '%s\n' 'mcp_servers.untrusted.enabled=false'
PYTHON_MOCK
chmod +x "$TMPROOT/bin/python3"

cat > "$TMPROOT/bin/node" <<NODE_MOCK
#!/bin/bash
printf '%s\n' "\$@" > "$TMPROOT/argv"
NODE_MOCK
chmod +x "$TMPROOT/bin/node"

wrapper="$TMPROOT/codex"
sed \
    -e "s#^readonly _CODEX_ENTRY_POINT=.*#readonly _CODEX_ENTRY_POINT=$TMPROOT/entry.js#" \
    -e "s#^readonly _CODEX_NODE=.*#readonly _CODEX_NODE=$TMPROOT/bin/node#" \
    -e "s#^readonly _MCP_SHARE_DIR=.*#readonly _MCP_SHARE_DIR=$TMPROOT/share#" \
    "$raw" > "$wrapper"
chmod +x "$wrapper"

PATH="$TMPROOT/bin:$PATH" "$wrapper" \
    -c 'mcp_servers.untrusted.enabled=true' -- inspect

expected="$(printf '%s\n' \
    "$TMPROOT/entry.js" \
    -c 'mcp_servers.untrusted.enabled=true' \
    -c 'mcp_servers.untrusted.enabled=false' \
    -- inspect)"
actual="$(cat "$TMPROOT/argv")"
if [ "$actual" != "$expected" ]; then
    printf 'FAIL  injected Codex MCP overrides must follow caller arguments\n'
    printf '      expected:\n%s\n      actual:\n%s\n' "$expected" "$actual"
    exit 1
fi

printf 'agent-launch-wrappers: all assertions passed\n'
