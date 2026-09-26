#!/usr/bin/env bash
# autonomous-action.sh の「はじめての日のチュートリアル」の関所を確かめる(2026-09-27)。
# 家 API の tutorial_state.py の代わりに、終了コードを選べる偽の python を置いて分岐だけを見る。
# claude・AWS・Docker には触らない(通る場合は --dry-run で止める)。
#
# Usage: bash scripts/tests/tutorial-gate.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
mkdir -p "$PETIT_DATA_DIR/characters/mio/config" "$PETIT_REPOS_DIR/m5-petit-app/scripts" \
         "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin" "$PETIT_MCP_DIR"
echo '# placeholder' > "$PETIT_REPOS_DIR/m5-petit-app/scripts/tutorial_state.py"
cat > "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GATE_CALLS"
echo "tutorial: fake"
exit "${FAKE_GATE_CODE:-0}"
PY
chmod +x "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/python"
export FAKE_GATE_CALLS="$WORK/calls"

fails=0
run_case() {  # 名前 期待(skip|run) 期待するログの語 [env...]
  local name="$1" expect="$2" word="$3"
  shift 3
  rm -rf "$PETIT_DATA_DIR/logs"
  : > "$FAKE_GATE_CALLS"
  env "$@" bash "$SCRIPT" mio --dry-run > /dev/null 2>&1
  local code=$?
  local log
  log="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
  local ok=true
  [ "$code" -eq 0 ] || ok=false
  if [ "$expect" = skip ]; then
    grep -q "DRY RUN" <<<"$log" && ok=false
  else
    grep -q "DRY RUN" <<<"$log" || ok=false
  fi
  if [ -n "$word" ]; then grep -q -- "$word" <<<"$log" || ok=false; fi
  if $ok; then echo "ok   $name"; else echo "FAIL $name (exit=$code)"; echo "$log" | head -5; fails=$((fails + 1)); fi
}

run_case "未完了なら抜ける"           skip "チュートリアル未完了のため自律行動しない" PETIT_HOUSE_TABLE=t FAKE_GATE_CODE=3
run_case "読めないときも抜ける"       skip "チュートリアルの状態を読めない"           PETIT_HOUSE_TABLE=t FAKE_GATE_CODE=2
run_case "達成済みなら続ける"         run  ""                                         PETIT_HOUSE_TABLE=t FAKE_GATE_CODE=0
run_case "家の表が無い環境は関所なし" run  ""                                         PETIT_HOUSE_TABLE=  FAKE_GATE_CODE=3
run_case "PETIT_TUTORIAL_GATE=0 で外す" run ""                                        PETIT_HOUSE_TABLE=t FAKE_GATE_CODE=3 PETIT_TUTORIAL_GATE=0

# 関所は tutorial_state.py <id> gate の形で呼ばれる
: > "$FAKE_GATE_CALLS"
env PETIT_HOUSE_TABLE=t FAKE_GATE_CODE=3 bash "$SCRIPT" mio --dry-run > /dev/null 2>&1
if grep -q "m5-petit-app/scripts/tutorial_state.py mio gate" "$FAKE_GATE_CALLS"; then
  echo "ok   引数が <id> gate"
else
  echo "FAIL 引数: $(cat "$FAKE_GATE_CALLS")"; fails=$((fails + 1))
fi

# 手で渡すプロンプト(-p)は関所を通らない(本物の claude を呼ばないよう、何もしない偽の claude を先に置く)
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "$WORK/bin/claude"
chmod +x "$WORK/bin/claude"
: > "$FAKE_GATE_CALLS"
env PETIT_HOUSE_TABLE=t FAKE_GATE_CODE=3 PATH="$WORK/bin:$PATH" \
  bash "$SCRIPT" mio -p "テスト" > /dev/null 2>&1
if [ ! -s "$FAKE_GATE_CALLS" ]; then echo "ok   -p は関所を通らない"; else echo "FAIL -p で関所が呼ばれた"; fails=$((fails + 1)); fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
