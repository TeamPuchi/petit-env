#!/usr/bin/env bash
# autonomous-action.sh の「おやすみモード」の関所を確かめる(akatsuki-petit#267・2026-10-27)。
# 家 API の scripts/*.py の代わりに、スクリプトごとに終了コードを選べる偽の python を置いて分岐だけを見る。
# claude・AWS・Docker には触らない(通る場合は --dry-run で止める)。
#
# Usage: bash scripts/tests/maintenance-gate.test.sh
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
echo '# placeholder' > "$PETIT_REPOS_DIR/m5-petit-app/scripts/lock_state.py"
# チュートリアル・メンテナンスの関所は常に 0。おやすみモードの関所だけ FAKE_LOCK_CODE で選ぶ
cat > "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GATE_CALLS"
case "$1" in
  *lock_state.py) echo "lock: fake"; exit "${FAKE_LOCK_CODE:-0}" ;;
  *) echo "fake"; exit 0 ;;
esac
PY
chmod +x "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/python"
export FAKE_GATE_CALLS="$WORK/calls"
export PETIT_SETTINGS_GATE=0  # 設定の関所は別(ここでは外す)

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

run_case "止まっている(3)なら抜ける"        skip "おやすみモードのため自律行動しない"           PETIT_HOUSE_TABLE=t FAKE_LOCK_CODE=3
run_case "動いてよい(0)なら続ける"          run  ""                                             PETIT_HOUSE_TABLE=t FAKE_LOCK_CODE=0
run_case "読めないときは今回は抜ける"       skip "おやすみモードの状態を読めないので今回は"     PETIT_HOUSE_TABLE=t FAKE_LOCK_CODE=2
run_case "家の表が無い環境は関所なし"       run  ""                                             PETIT_HOUSE_TABLE=  FAKE_LOCK_CODE=3
run_case "PETIT_LOCK_GATE=0 で外す"         run  ""                                             PETIT_HOUSE_TABLE=t FAKE_LOCK_CODE=3 PETIT_LOCK_GATE=0

# 関所は lock_state.py <ぷちの id> gate の形で呼ばれる(ぷちごとの状態)
: > "$FAKE_GATE_CALLS"
env PETIT_HOUSE_TABLE=t FAKE_LOCK_CODE=3 bash "$SCRIPT" mio --dry-run > /dev/null 2>&1
if grep -q "m5-petit-app/scripts/lock_state.py mio gate$" "$FAKE_GATE_CALLS"; then
  echo "ok   引数が <id> gate"
else
  echo "FAIL 引数: $(cat "$FAKE_GATE_CALLS")"; fails=$((fails + 1))
fi

# 関所の入っていない古い家 API(lock_state.py が無い)では、関所なしで続ける
rm "$PETIT_REPOS_DIR/m5-petit-app/scripts/lock_state.py"
run_case "古い家 API では関所なし"          run  ""                                             PETIT_HOUSE_TABLE=t FAKE_LOCK_CODE=3
echo '# placeholder' > "$PETIT_REPOS_DIR/m5-petit-app/scripts/lock_state.py"

# 手で渡すプロンプト(-p)は関所を通らない(本物の claude を呼ばないよう、何もしない偽の claude を先に置く)
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "$WORK/bin/claude"
chmod +x "$WORK/bin/claude"
: > "$FAKE_GATE_CALLS"
env PETIT_HOUSE_TABLE=t FAKE_LOCK_CODE=3 PATH="$WORK/bin:$PATH" \
  bash "$SCRIPT" mio -p "テスト" > /dev/null 2>&1
if ! grep -q "lock_state.py" "$FAKE_GATE_CALLS"; then echo "ok   -p は関所を通らない"; else echo "FAIL -p で関所が呼ばれた"; fails=$((fails + 1)); fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
