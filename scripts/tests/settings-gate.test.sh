#!/usr/bin/env bash
# autonomous-action.sh の「設定の関所」を確かめる(akatsuki-petit#159)。
# 家 API の settings_state.py の代わりに、終了コードと出力を選べる偽の python を置いて分岐だけを見る。
# チュートリアルの関所は偽の python が 0(達成済み)を返して通す。claude・AWS・Docker には触らない
# (通る場合は --dry-run で止める)。時刻は --date で 10:20(既定の時間帯の外・0分でない)に固定するので、
# 関所を通らなければ settings.json 側の判定で「非アクティブ時間帯」になって止まる。
#
# Usage: bash scripts/tests/settings-gate.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
API="$PETIT_REPOS_DIR/m5-petit-app"
mkdir -p "$PETIT_DATA_DIR/characters/mio/config" "$API/scripts" "$API/.venv/bin" "$PETIT_MCP_DIR"
echo '# placeholder' > "$API/scripts/tutorial_state.py"
echo '# placeholder' > "$API/scripts/settings_state.py"
cat > "$API/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
case "$1" in
  *settings_state.py)
    echo "$*" >> "$FAKE_GATE_CALLS"
    echo "${FAKE_SETTINGS_OUT:-settings: fake camera=on speaker=on}"
    exit "${FAKE_SETTINGS_CODE:-0}"
    ;;
  *tutorial_state.py)
    echo "tutorial: done"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
PY
chmod +x "$API/.venv/bin/python"
export FAKE_GATE_CALLS="$WORK/calls"
DATE="2026-09-29 10:20"

fails=0
run_case() {  # 名前 期待(skip|run) 期待するログの語 [env...]
  local name="$1" expect="$2" word="$3"
  shift 3
  rm -rf "$PETIT_DATA_DIR/logs"
  : > "$FAKE_GATE_CALLS"
  env "$@" bash "$SCRIPT" mio --dry-run --date "$DATE" > /dev/null 2>&1
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

run_case "関所が動くと言えば、時間帯の外でも動く" run  "設定の関所: settings: fake"      PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=0
run_case "関所が休むと言えば抜ける"               skip "設定の関所: settings: skip"      PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=3 FAKE_SETTINGS_OUT="settings: skip (off) camera=on speaker=on"
run_case "読めないときは settings.json で決める"  skip "設定を読めないので settings.json" PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=2
run_case "PETIT_SETTINGS_GATE=0 で外す"           skip "非アクティブ時間帯"              PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=0 PETIT_SETTINGS_GATE=0
run_case "家の表が無い環境は関所なし"             skip "非アクティブ時間帯"              PETIT_HOUSE_TABLE=  FAKE_SETTINGS_CODE=0
run_case "カメラを閉じていれば制限に足す"         run  "目(カメラ)は里親が閉じている"    PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=0 FAKE_SETTINGS_OUT="settings: run (active) camera=off speaker=on"
run_case "お喋りを止めていれば制限に足す"         run  "お喋り(スピーカー)は里親が止めている" PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=0 FAKE_SETTINGS_OUT="settings: run (active) camera=on speaker=off"

# 関所は settings_state.py <id> gate --now … --file … --dry-run の形で呼ばれる
: > "$FAKE_GATE_CALLS"
env PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=3 bash "$SCRIPT" mio --dry-run --date "$DATE" > /dev/null 2>&1
if grep -q "m5-petit-app/scripts/settings_state.py mio gate --now 2026-09-29 10:20:00 --file .*/characters/mio/config/settings.json --dry-run" "$FAKE_GATE_CALLS"; then
  echo "ok   引数が <id> gate --now --file --dry-run"
else
  echo "FAIL 引数: $(cat "$FAKE_GATE_CALLS")"; fails=$((fails + 1))
fi

# --date なしの dry-run はスケジュールを見ない(関所も呼ばない)
: > "$FAKE_GATE_CALLS"
env PETIT_HOUSE_TABLE=t FAKE_SETTINGS_CODE=3 bash "$SCRIPT" mio --dry-run > /dev/null 2>&1
if [ ! -s "$FAKE_GATE_CALLS" ]; then echo "ok   --date なしの dry-run は関所を通らない"; else echo "FAIL --date なしで関所が呼ばれた"; fails=$((fails + 1)); fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
