#!/usr/bin/env bash
# 頭脳の原価を下げる（W12・2026-09-30）の載せ方を確かめる。
# - gen-mcp-config.sh: PETIT_MCP_ALWAYS_LOAD に書いたサーバーだけ "alwaysLoad": true（既定は付けない）
# - autonomous-action.sh:
#   - claude に --model（既定 sonnet）・--tools（使う組み込みの道具だけ）を付ける
#   - --max-turns は settings.json の値を PETIT_AUTONOMOUS_MAX_TURNS（既定 5）で頭打ち。MAX_TURNS を渡せばそれ
#   - 前の回の文脈が PETIT_AUTONOMOUS_CONTEXT_MAX（既定 30000）を越えていたら、続きにせず新しいセッション
#   - 回の終わりに文脈の大きさ（数だけ）を state に残す
#   - プロンプトに「1つか2つで足りる」「1つの出来事は1か所に1回」
# claude と家 API の python は偽物を置く。claude・AWS には触らない。
#
# Usage: bash scripts/tests/brain-cost.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
CHAR="$PETIT_DATA_DIR/characters/mio"
mkdir -p "$CHAR/config" "$CHAR/state" "$PETIT_MCP_DIR" "$WORK/bin"
echo '{"max_turns": 20}' > "$CHAR/config/settings.json"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# 1. gen-mcp-config.sh
bash "$HERE/gen-mcp-config.sh" mio > /dev/null
mkdir -p "$PETIT_REPOS_DIR/petit-desire"; echo '[project]' > "$PETIT_REPOS_DIR/petit-desire/pyproject.toml"
bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '.mcpServers["desire-system"].alwaysLoad == true and ([.mcpServers.memory, .mcpServers["petit-sns"]] | map(has("alwaysLoad")) | any | not)' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "既定では desire-system だけ alwaysLoad" $?
PETIT_MCP_ALWAYS_LOAD= bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '[.mcpServers[] | has("alwaysLoad")] | any | not' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "PETIT_MCP_ALWAYS_LOAD を空にすると付けない" $?
PETIT_MCP_ALWAYS_LOAD="petit-sns, memory" bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '.mcpServers.memory.alwaysLoad == true and .mcpServers["petit-sns"].alwaysLoad == true' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "PETIT_MCP_ALWAYS_LOAD のサーバーに alwaysLoad" $?
jq -e '.mcpServers.memory.env.PETIT_MEMORY_PETIT_ID == "mio"' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "ほかの中身はそのまま" $?
bash "$HERE/gen-mcp-config.sh" mio > /dev/null  # 以降は既定の設定で

# 2. autonomous-action.sh（偽の claude: 引数を残し、assistant 2 行と result 行を出す）
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo "$*" >> "$FAKE_CLAUDE_ARGS"
echo '{"type":"system","subtype":"init","model":"claude-sonnet-5"}'
echo '{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":3,"cache_creation_input_tokens":8000,"cache_read_input_tokens":0,"output_tokens":5}}}'
echo "{\"type\":\"assistant\",\"message\":{\"id\":\"m2\",\"content\":[],\"usage\":{\"input_tokens\":2,\"cache_creation_input_tokens\":500,\"cache_read_input_tokens\":${FAKE_LAST_READ:-8000},\"output_tokens\":5}}}"
echo '{"type":"result","subtype":"success","session_id":"s-new","num_turns":2,"total_cost_usd":0.03}'
SH
chmod +x "$WORK/bin/claude"
export FAKE_CLAUDE_ARGS="$WORK/claude-args"
run() {  # run [env...]
  : > "$FAKE_CLAUDE_ARGS"
  env PETIT_HOUSE_TABLE= PATH="$WORK/bin:$PATH" "$@" bash "$SCRIPT" mio -p "おさんぽしよう" > /dev/null 2>&1
}
arg_of() {  # arg_of <flag> — 最後の呼び出しでの値
  tail -n 1 "$FAKE_CLAUDE_ARGS" | tr ' ' '\n' | grep -A1 -x -- "$1" | tail -n 1
}

rm -f "$CHAR/state/.heartbeat-session-id" "$CHAR/state/.heartbeat-session-context"
run
[ "$(arg_of --model)" = "sonnet" ]; check "--model は既定 sonnet" $?
[ "$(arg_of --tools)" = "Read,Write,Edit,Glob,Skill,WebSearch,WebFetch,ToolSearch" ]; check "--tools は使う組み込みの道具だけ" $?
[ "$(arg_of --max-turns)" = "5" ]; check "settings.json の 20 を 5 で頭打ち" $?
[ "$(cat "$CHAR/state/.heartbeat-session-context")" = "8502" ]; check "最後の呼び出しの文脈を残す" $?

run CLAUDE_MODEL=haiku MAX_TURNS=8 PETIT_AUTONOMOUS_TOOLS=
[ "$(arg_of --model)" = "haiku" ]; check "CLAUDE_MODEL で変えられる" $?
[ "$(arg_of --max-turns)" = "8" ]; check "MAX_TURNS を渡せばそれ" $?
! grep -q -- "--tools" "$FAKE_CLAUDE_ARGS"; check "PETIT_AUTONOMOUS_TOOLS を空にすると --tools を付けない" $?

run PETIT_AUTONOMOUS_MAX_TURNS=0
[ "$(arg_of --max-turns)" = "20" ]; check "PETIT_AUTONOMOUS_MAX_TURNS=0 で頭打ちしない" $?
run PETIT_AUTONOMOUS_MAX_TURNS=3
[ "$(arg_of --max-turns)" = "3" ]; check "PETIT_AUTONOMOUS_MAX_TURNS=3" $?

# 文脈が小さければ続きにする・大きければ新しいセッション
echo old > "$CHAR/state/.heartbeat-session-id"
date "+%Y-%m-%d" > "$CHAR/state/.heartbeat-session-date"
echo 12000 > "$CHAR/state/.heartbeat-session-context"
run
grep -q -- "--resume old" "$FAKE_CLAUDE_ARGS"; check "前の文脈が上限の内なら続きにする" $?
echo old > "$CHAR/state/.heartbeat-session-id"
echo 45000 > "$CHAR/state/.heartbeat-session-context"
run
! grep -q -- "--resume" "$FAKE_CLAUDE_ARGS"; check "前の文脈が上限を越えていたら新しいセッション" $?
[ "$(cat "$CHAR/state/.heartbeat-session-id")" = "s-new" ]; check "新しいセッションの id を残す" $?
echo 45000 > "$CHAR/state/.heartbeat-session-context"
run PETIT_AUTONOMOUS_CONTEXT_MAX=0
grep -q -- "--resume s-new" "$FAKE_CLAUDE_ARGS"; check "PETIT_AUTONOMOUS_CONTEXT_MAX=0 なら上限なし（前のまま）" $?

# プロンプト（--dry-run で見る）
OUT=$(env PETIT_HOUSE_TABLE= PATH="$WORK/bin:$PATH" bash "$SCRIPT" mio --dry-run 2>/dev/null)
echo "$OUT" | grep -q "1回の自律行動でやることは、1つか2つで足りる"; check "プロンプト: 1つか2つで足りる" $?
echo "$OUT" | grep -q "同じ中身をいくつもの置き場に重ねて書かない"; check "プロンプト: 重ねて書かない" $?
echo "$OUT" | grep -q "同じ回の中でもう一度 remember しなくてよい"; check "プロンプト: 同じ remember を繰り返さない" $?
echo "$OUT" | grep -q "気づいたことを日誌のように毎回書き足さなくてよい"; check "プロンプト: TODO を日誌にしない" $?
echo "$OUT" | grep -q "\[MODEL\] sonnet \[MAX_TURNS\] 5"; check "dry-run にモデル・ターンを出す" $?

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
