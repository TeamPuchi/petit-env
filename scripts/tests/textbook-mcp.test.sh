#!/usr/bin/env bash
# 教科書の MCP（petit-textbook・10/27 Sync 40番）の載せ方を確かめる。
# - gen-mcp-config.sh: petit-textbook の mcp/ があるときだけ mcpServers.petit-textbook を書く
# - autonomous-action.sh: allowedTools に読む道具（index・read・search・version）が入り、textbook_propose は入らない
# claude・AWS・Docker には触らない。
#
# Usage: bash scripts/tests/textbook-mcp.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
mkdir -p "$PETIT_DATA_DIR/characters/mio/config" "$PETIT_MCP_DIR"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# 1. 焼き込まれていなければ載せない
bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '.mcpServers | has("petit-textbook") | not' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "petit-textbook が無ければ載せない" $?

# 2. あれば載せる（焼き込み済みの venv の実行ファイルを直接使う）。教科書の場所はリポの根
mkdir -p "$PETIT_REPOS_DIR/petit-textbook/mcp/.venv/bin"
echo '[project]' > "$PETIT_REPOS_DIR/petit-textbook/mcp/pyproject.toml"
printf '#!/bin/sh\n' > "$PETIT_REPOS_DIR/petit-textbook/mcp/.venv/bin/textbook-mcp"
chmod +x "$PETIT_REPOS_DIR/petit-textbook/mcp/.venv/bin/textbook-mcp"
bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e --arg c "$PETIT_REPOS_DIR/petit-textbook/mcp/.venv/bin/textbook-mcp" --arg d "$PETIT_REPOS_DIR/petit-textbook" \
  '.mcpServers."petit-textbook" | .command == $c and .env.CHARACTER_ID == "mio" and .env.PETIT_TEXTBOOK_DIR == $d' \
  "$PETIT_MCP_DIR/mio.json" > /dev/null
check "あれば petit-textbook を載せる（CHARACTER_ID・PETIT_TEXTBOOK_DIR）" $?
jq -e '.mcpServers | has("memory") and has("petit-sns")' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "memory・petit-sns はそのまま" $?

# 3. 自律行動の allowedTools: 読む道具は入り、提案（ファイルのノートに書く）は入らない
rm -rf "$PETIT_DATA_DIR/logs"
PETIT_HOUSE_TABLE= bash "$HERE/autonomous-action.sh" mio --dry-run > /dev/null 2>&1
log="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
for t in textbook_index textbook_read textbook_search textbook_version; do
  grep -qx "mcp__petit-textbook__$t" <<<"$log"
  check "allowedTools に mcp__petit-textbook__$t" $?
done
! grep -q "mcp__petit-textbook__textbook_propose" <<<"$log"
check "allowedTools に textbook_propose は入れない" $?

echo
[ "$fails" -eq 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
