#!/usr/bin/env bash
# 頭脳の原価を下げる（W12・2026-09-30）の載せ方を確かめる。
# - gen-mcp-config.sh: PETIT_MCP_ALWAYS_LOAD に書いたサーバーだけ "alwaysLoad": true（既定は付けない）
#   最初から載せる道具の一覧（scripts/preload-tools.txt・2026-10-03）をサーバーごとに分けて env の PETIT_PRELOAD_TOOLS に
#   - check-preload-tools.py: 一覧の名前が実在して印が付いているか（mcp の入った python があるときだけ・偽のサーバーで）
# - autonomous-action.sh:
#   - claude に --model（既定 claude-sonnet-5-5・W15）・--tools（使う組み込みの道具だけ）を付ける
#   - --max-turns は settings.json の値を PETIT_AUTONOMOUS_MAX_TURNS（既定 5）で頭打ち。MAX_TURNS を渡せばそれ
#   - 前の回の文脈が PETIT_AUTONOMOUS_CONTEXT_MAX（既定 30000）を越えていたら、続きにせず新しいセッション
#   - 回の終わりに文脈の大きさ（数だけ）を state に残す
#   - ログの [usage] の額は 1 回ぶん（cost_usd）とセッションの累計（cost_session_usd）を分けて書く（2026-10-11）
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
jq -e '[.mcpServers[] | has("alwaysLoad")] | any | not' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "既定ではどのサーバーにも alwaysLoad を付けない（道具ごとの一覧で載せる）" $?
PETIT_MCP_ALWAYS_LOAD="petit-sns, memory" bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '.mcpServers.memory.alwaysLoad == true and .mcpServers["petit-sns"].alwaysLoad == true' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "PETIT_MCP_ALWAYS_LOAD のサーバーに alwaysLoad" $?
jq -e '.mcpServers.memory.env.PETIT_MEMORY_PETIT_ID == "mio"' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "ほかの中身はそのまま" $?

# 1b. 最初から載せる道具の一覧（1か所: scripts/preload-tools.txt）
LIST="$(sed 's/#.*//' "$HERE/preload-tools.txt" | tr -d ' \t\r' | grep -v '^$')"
[ -n "$LIST" ] && ! grep -qv '^mcp__[A-Za-z0-9-]*__[A-Za-z0-9_]*$' <<< "$LIST"
check "一覧は mcp__<サーバー>__<道具> だけ" $?
[ -z "$(sort <<< "$LIST" | uniq -d)" ]; check "一覧に同じ名前が2回無い" $?
n="$(wc -l <<< "$LIST")"; [ "$n" -ge 3 ] && [ "$n" -le 20 ]; check "一覧はよく使う十数個まで（$n 個）" $?
mkdir -p "$PETIT_REPOS_DIR/m5-petit-app"; echo '# placeholder' > "$PETIT_REPOS_DIR/m5-petit-app/house_mcp.py"
bash "$HERE/gen-mcp-config.sh" mio > /dev/null 2> "$WORK/gen.err"
for s in memory petit-sns desire-system house; do
  want="$(grep "^mcp__${s}__" <<< "$LIST" | sed "s/^mcp__${s}__//" | paste -sd, -)"
  jq -e --arg s "$s" --arg w "$want" '.mcpServers[$s].env.PETIT_PRELOAD_TOOLS == $w' "$PETIT_MCP_DIR/mio.json" > /dev/null
  check "$s の env.PETIT_PRELOAD_TOOLS は一覧のその サーバーの分（$want）" $?
done
[ ! -s "$WORK/gen.err" ]; check "既定の一覧はどれもサーバーに当たる（警告が出ない）" $?
PETIT_PRELOAD_TOOLS=" mcp__memory__remember,mcp__house__note_write , mcp__house__body_now,WebSearch,mcp__nope__x" \
  bash "$HERE/gen-mcp-config.sh" mio > /dev/null 2> "$WORK/gen.err"
jq -e '.mcpServers.memory.env.PETIT_PRELOAD_TOOLS == "remember" and .mcpServers.house.env.PETIT_PRELOAD_TOOLS == "note_write,body_now"
       and .mcpServers["petit-sns"].env.PETIT_PRELOAD_TOOLS == "" and .mcpServers["desire-system"].env.PETIT_PRELOAD_TOOLS == ""' \
  "$PETIT_MCP_DIR/mio.json" > /dev/null
check "env PETIT_PRELOAD_TOOLS があればファイルの代わりにそれ（無いサーバーは空で入れる）" $?
grep -q "WebSearch" "$WORK/gen.err" && grep -q "mcp__nope__x" "$WORK/gen.err"
check "どのサーバーにも当たらない名前は警告" $?
PETIT_PRELOAD_TOOLS= bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '[.mcpServers[].env.PETIT_PRELOAD_TOOLS] | all(. == "")' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "PETIT_PRELOAD_TOOLS を空にすると何も載せない" $?
printf 'mcp__petit-sns__sns_post  # コメント\r\n\r\n# 行ごとコメント\r\nmcp__house__mail_read\r\n' > "$WORK/list.txt"
PETIT_PRELOAD_TOOLS_FILE="$WORK/list.txt" bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '.mcpServers["petit-sns"].env.PETIT_PRELOAD_TOOLS == "sns_post" and .mcpServers.house.env.PETIT_PRELOAD_TOOLS == "mail_read"' \
  "$PETIT_MCP_DIR/mio.json" > /dev/null
check "一覧のファイルはコメント・空行・CRLF を読み飛ばす" $?
rm -f "$PETIT_REPOS_DIR/m5-petit-app/house_mcp.py"

# 1c. check-preload-tools.py（偽の MCP サーバー2つ: 印を付けるもの・付けないもの）
PY="${PETIT_MCP_PYTHON:-python3}"
if "$PY" -c 'import mcp' 2>/dev/null; then
  cat > "$WORK/fake_server.py" <<'PY'
import os, sys
try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    from mcp.server.mcpserver import MCPServer as FastMCP
mcp = FastMCP("fake")
@mcp.tool()
def alpha() -> str:
    "a"
    return "a"
@mcp.tool()
def beta(x: int = 0) -> str:
    "b"
    return "b"
if os.environ.get("FAKE_HONOR") == "1":
    want = [n for n in os.environ.get("PETIT_PRELOAD_TOOLS", "").split(",") if n]
    for t in mcp._tool_manager.list_tools():
        if t.name in want:
            t.meta = {"anthropic/alwaysLoad": True}
mcp.run()
PY
  jq -n --arg py "$PY" --arg f "$WORK/fake_server.py" \
    '{mcpServers: {good: {command: $py, args: [$f], env: {FAKE_HONOR: "1", PETIT_PRELOAD_TOOLS: "alpha"}}}}' > "$WORK/ok.json"
  "$PY" "$HERE/check-preload-tools.py" "$WORK/ok.json" --sizes > "$WORK/chk.out" 2>&1
  check "check-preload-tools: 一覧の道具が実在して印が付いていれば 0" $?
  grep -q '\* .* alpha' "$WORK/chk.out"; check "check-preload-tools: --sizes に載せる印" $?
  jq -n --arg py "$PY" --arg f "$WORK/fake_server.py" \
    '{mcpServers: {good: {command: $py, args: [$f], env: {FAKE_HONOR: "1", PETIT_PRELOAD_TOOLS: "alpha,gamma"}},
                   deaf: {command: $py, args: [$f], env: {PETIT_PRELOAD_TOOLS: "beta"}}}}' > "$WORK/ng.json"
  "$PY" "$HERE/check-preload-tools.py" "$WORK/ng.json" > "$WORK/chk.out" 2>&1
  [ $? -eq 1 ]; check "check-preload-tools: 食い違いがあれば 1" $?
  grep -q '^NG good: .*gamma' "$WORK/chk.out"; check "check-preload-tools: 実在しない名前を出す" $?
  grep -q '^NG deaf: .*beta' "$WORK/chk.out"; check "check-preload-tools: 印の付いていない道具を出す" $?
else
  echo "skip check-preload-tools（mcp の入った python が無い。PETIT_MCP_PYTHON=<家 API の .venv の python> で動く）"
fi

bash "$HERE/gen-mcp-config.sh" mio > /dev/null  # 以降は既定の設定で

# 2. autonomous-action.sh（偽の claude: 引数を残し、assistant 2 行と result 行を出す）
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo "$*" >> "$FAKE_CLAUDE_ARGS"
echo '{"type":"system","subtype":"init","model":"claude-sonnet-5"}'
echo '{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":3,"cache_creation_input_tokens":8000,"cache_read_input_tokens":0,"output_tokens":5}}}'
echo "{\"type\":\"assistant\",\"message\":{\"id\":\"m2\",\"content\":[],\"usage\":{\"input_tokens\":2,\"cache_creation_input_tokens\":500,\"cache_read_input_tokens\":${FAKE_LAST_READ:-8000},\"output_tokens\":5}}}"
[ -n "${FAKE_NO_RESULT:-}" ] && exit 0
echo "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"${FAKE_SID:-s-new}\",\"num_turns\":2,\"total_cost_usd\":${FAKE_COST:-0.03}}"
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
[ "$(arg_of --model)" = "claude-sonnet-5-5" ]; check "--model は既定 claude-sonnet-5-5（正式名）" $?
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

# 額は 1 回ぶん（cost_usd）とセッションの累計（cost_session_usd）を分けてログに書く（2026-10-11）
# CLI の total_cost_usd は --resume で続けたセッションの累計（家 API の tests/test_brain_cost.py と同じ数で確かめる）
last_usage() { cat "$PETIT_DATA_DIR"/logs/mio/*.log | grep '^\[usage\]' | tail -n 1; }
rm -f "$CHAR/state/.heartbeat-session-id" "$CHAR/state/.heartbeat-session-context" "$CHAR/state/.heartbeat-session-cost"
run FAKE_SID=s1 FAKE_COST=0.243484
last_usage | grep -q "type=new turns=2 cost_usd=0.243484 cost_session_usd=0.243484 "; check "新しいセッションの回は CLI の額そのまま" $?
[ "$(cat "$CHAR/state/.heartbeat-session-cost")" = "s1 0.243484" ]; check "セッションと累計を state に残す" $?
run FAKE_SID=s1 FAKE_COST=1.52038
last_usage | grep -q "type=resume turns=2 cost_usd=1.276896 cost_session_usd=1.52038 "; check "続きの回は前の回の累計を引く（1.52038 - 0.243484）" $?
run FAKE_SID=s1 FAKE_COST=1.6041528
last_usage | grep -q "type=resume turns=2 cost_usd=0.083773 cost_session_usd=1.6041528 "; check "もう1回続けても前の回との差（1.6041528 - 1.52038）" $?
rm -f "$CHAR/state/.heartbeat-session-cost"
run FAKE_SID=s1 FAKE_COST=1.7
last_usage | grep -q "type=resume turns=2 cost_usd=? cost_session_usd=1.7 "; check "前の回の累計が分からない続きの回は ?（累計を 1 回ぶんとして書かない）" $?
echo "other 0.1" > "$CHAR/state/.heartbeat-session-cost"
run FAKE_SID=s1 FAKE_COST=1.8
last_usage | grep -q "type=resume turns=2 cost_usd=? cost_session_usd=1.8 "; check "別のセッションの累計は引かない" $?
echo "s1 2.0" > "$CHAR/state/.heartbeat-session-cost"
run FAKE_SID=s1 FAKE_COST=0.5
last_usage | grep -q "type=resume turns=2 cost_usd=? cost_session_usd=0.5 "; check "累計が前の回より減ったら ?" $?
[ "$(cat "$CHAR/state/.heartbeat-session-cost")" = "s1 0.5" ]; check "減っても今の累計に置き換える（次の回はここから引く）" $?
run FAKE_SID=s1 FAKE_COST=0.6
last_usage | grep -q "type=resume turns=2 cost_usd=0.100000 cost_session_usd=0.6 "; check "置き換えた累計から引く" $?
run FAKE_NO_RESULT=1
last_usage | grep -q "cost_usd=? cost_session_usd=? "; check "result 行が無い回（上限時間など）は ?（0 と書かない）" $?
[ "$(cat "$CHAR/state/.heartbeat-session-cost")" = "s1 0.6" ]; check "result 行が無い回は state の累計を変えない" $?
rm -f "$CHAR/state/.heartbeat-session-id" "$CHAR/state/.heartbeat-session-cost"

# プロンプト（--dry-run で見る）
OUT=$(env PETIT_HOUSE_TABLE= PATH="$WORK/bin:$PATH" bash "$SCRIPT" mio --dry-run 2>/dev/null)
echo "$OUT" | grep -q "1回の自律行動でやることは、1つか2つで足りる"; check "プロンプト: 1つか2つで足りる" $?
echo "$OUT" | grep -q "同じ中身をいくつもの置き場に重ねて書かない"; check "プロンプト: 重ねて書かない" $?
echo "$OUT" | grep -q "同じ回の中でもう一度 remember しなくてよい"; check "プロンプト: 同じ remember を繰り返さない" $?
echo "$OUT" | grep -q "気づいたことを日誌のように毎回書き足さなくてよい"; check "プロンプト: TODO を日誌にしない" $?
echo "$OUT" | grep -q "\[MODEL\] claude-sonnet-5-5 \[MAX_TURNS\] 5"; check "dry-run にモデル・ターンを出す" $?

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
