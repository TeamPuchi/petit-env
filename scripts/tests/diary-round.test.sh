#!/usr/bin/env bash
# 夜の「今日をふり返る回」(autonomous-action.sh --diary・T4 なぎさん 2026-10-12)を確かめる。
# - 家 API の scripts/diary_material.py <id> の出力を「## 今日の材料」としてプロンプトに入れ、diary_write で書けと言う
# - 設定の関所に --diary を渡す(自律行動 OFF でも通る)。活動時間の外でも動く。メンテナンスの関所は通らない(日記は止めない)
# - 材料が無い日(終了コード 3)・diary_material.py の無い古い家 API・家の表が無い環境では claude を呼ばない
# - 欲求・未読の手紙・体の知らせは出さない(その回の材料は別に渡す)。ルーチン回にはならない
# - 台帳・全文ログの source は diary。終わりに diary_write を呼んだかをログに残す(本文は残さない)
# - 前の回が動いていれば終わるまで待つ(待ちきれなければ抜ける)
# claude と家 API の python は偽物を置く。claude・AWS には触らない。flock が要る(Linux / WSL で動かす)。
#
# Usage: bash scripts/tests/diary-round.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
CHAR="$PETIT_DATA_DIR/characters/mio"
API="$PETIT_REPOS_DIR/m5-petit-app"
mkdir -p "$CHAR/config" "$CHAR/state" "$API/scripts" "$API/.venv/bin" "$PETIT_MCP_DIR" "$WORK/bin"
echo '{"active_hours": [[10, 11]]}' > "$CHAR/config/settings.json"   # 20:30 は活動時間の外
printf '## 最新の日記（2026-10-11）\n\nきのうの日記。\n' > "$CHAR/diary_summary.md"
for f in tutorial_state.py settings_state.py maintenance_state.py record_usage.py archive_stream.py \
         diary_material.py body_news.py read_mailbox.py; do echo '# placeholder' > "$API/scripts/$f"; done
# 偽の家 API の python: 呼ばれた引数を残す。関所は通す(FAKE_MAINT_PAUSE ならメンテナンスの関所が「休め」と言う)
cat > "$API/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_PY_CALLS"
case "$1" in
  *settings_state.py) echo "settings: run (diary (autonomous off)) camera=on speaker=on sns=on" ;;
  *tutorial_state.py) echo "tutorial: done" ;;
  *maintenance_state.py) [ -n "${FAKE_MAINT_PAUSE:-}" ] && { echo "maintenance: on (pause_petits)"; exit 3; }; echo "maintenance: off" ;;
  *diary_material.py)
    [ -n "${FAKE_NO_MATERIAL:-}" ] && exit 3
    printf '## 今日の会話（古い順）\n[09:00] なぎ: おはよう\n[09:01] 澪: おはよう！\n\n## 今日の出来事（今日できた記憶、古い順）\n[15:00] 猫を見た\n' ;;
  *body_news.py) echo "触られた 1 回" ;;
  *read_mailbox.py) echo 2 ;;
esac
exit 0
PY
chmod +x "$API/.venv/bin/python"
# 偽の claude: プロンプトを写し、(頼まれれば)diary_write を呼んだ行を出してから result 行を出す
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
cat > "$FAKE_CLAUDE_PROMPT"
echo called >> "$FAKE_CLAUDE_CALLS"
[ -n "${FAKE_CLAUDE_WROTE:-}" ] && echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__house__diary_write","input":{"body":"ひみつの本文"}}],"usage":{"input_tokens":10}}}'
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"s1","total_cost_usd":0.01,"num_turns":2}'
SH
chmod +x "$WORK/bin/claude"
export FAKE_PY_CALLS="$WORK/py-calls" FAKE_CLAUDE_CALLS="$WORK/claude-calls" FAKE_CLAUDE_PROMPT="$WORK/prompt"
DATE="2026-10-12 20:30"
LOCK="$CHAR/state/.autonomous.lock"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
reset() { rm -rf "$PETIT_DATA_DIR/logs" "$CHAR/state/.heartbeat-session-"*; : > "$FAKE_PY_CALLS"; : > "$FAKE_CLAUDE_CALLS"; : > "$FAKE_CLAUDE_PROMPT"; }
log() { cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null; }
run() { env PATH="$WORK/bin:$PATH" "$@" > /dev/null 2>&1; }

# 1. dry-run: 関所・材料・プロンプト
reset
OUT=$(env PETIT_HOUSE_TABLE=t PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" --diary 2>/dev/null)
grep -q "DRY RUN" <<< "$OUT"; check "活動時間の外(20:30・settings.json は 10〜11 時)でも今日をふり返る回は動く" $?
grep -q "settings_state.py mio gate .*--diary" "$FAKE_PY_CALLS"; check "設定の関所に --diary を渡す" $?
! grep -q "maintenance_state.py" "$FAKE_PY_CALLS"; check "メンテナンスの関所は見ない" $?
grep -q "diary_material.py mio" "$FAKE_PY_CALLS"; check "家 API の diary_material.py <id> で今日の材料を読む" $?
grep -q "自律行動タイム(Heartbeat)・今日をふり返る回" <<< "$OUT" && grep -q "今日一日をふり返る回" <<< "$OUT"
check "プロンプトは今日をふり返る回" $?
grep -q "記憶の整理: " <<< "$OUT" && grep -q "記憶の統合: " <<< "$OUT" && grep -q "3. 日記: " <<< "$OUT"
check "日記の前に、記憶の整理と統合を自分でする(なぎさん 2026-10-28)" $?
grep -q "mcp__memory__forget" <<< "$OUT"; check "忘れる道具 forget を許可する" $?
grep -q "## 今日の材料" <<< "$OUT" && grep -q "\[09:00\] なぎ: おはよう" <<< "$OUT" && grep -q "\[15:00\] 猫を見た" <<< "$OUT"
check "材料(会話・記憶)がプロンプトに入る" $?
grep -q "@$CHAR/SOUL.md" <<< "$OUT" && grep -q "@$CHAR/diary_summary.md" <<< "$OUT"
check "SOUL.md と日記のまとめ(きのうまで)を読む" $?
grep -q "house の diary_write に本文だけを渡す" <<< "$OUT" && grep -q "diary_append で足す" <<< "$OUT"
check "diary_write で書け(もうあれば diary_append)と言う" $?
grep -q "気持ちが大きく動いたことから書く" <<< "$OUT" && grep -q "5〜8 行、長くても 10 行ほど" <<< "$OUT"
check "書き方(全部並べない・気持ちが動いたことから・5〜8 行)を言う" $?
grep -q "list_recent_memories" <<< "$OUT"; check "記憶も見返してよいと言う" $?
grep -q "手紙・ボイスメモ・SNS・声(body_speak)は使わない" <<< "$OUT"; check "この回では手紙・ボイスメモ・SNS・声を使わない" $?
! grep -q "## お願い" <<< "$OUT" && ! grep -q "ルーチン回。" <<< "$OUT" && ! grep -q "## いまの気分" <<< "$OUT" \
  && ! grep -q "## 手紙" <<< "$OUT" && ! grep -q "触られた 1 回" <<< "$OUT"
check "ルーチン・欲求・未読の手紙・体の知らせは出さない" $?
! grep -q "body_news.py\|read_mailbox.py" "$FAKE_PY_CALLS"; check "体の知らせ・未読の手紙の件数は読まない(位置も動かさない)" $?
grep -q "\[SOURCE=diary\]" <<< "$OUT" && grep -q "\[DIARY\] 今日をふり返る回(材料 [0-9]* 行)" <<< "$OUT"
check "dry-run に SOURCE=diary と材料の行数を出す" $?
grep -qx "mcp__house__diary_write" <<< "$OUT" && grep -qx "mcp__house__diary_append" <<< "$OUT"
check "allowedTools に diary_write・diary_append" $?

# 2. 材料が無い日・古い家 API・家の表が無い環境では動かない
reset
OUT=$(env PETIT_HOUSE_TABLE=t FAKE_NO_MATERIAL=1 PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" --diary 2>/dev/null)
! grep -q "DRY RUN" <<< "$OUT" && grep -q "今日は会話も記憶も無いので、日記は書かない" <<< "$(log)"
check "会話も記憶も無い日(終了コード 3)は claude を呼ばない" $?
reset
mv "$API/scripts/diary_material.py" "$WORK/diary_material.py.bak"
OUT=$(env PETIT_HOUSE_TABLE=t PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" --diary 2>/dev/null)
! grep -q "DRY RUN" <<< "$OUT" && grep -q "diary_material.py が無いので" <<< "$(log)"
check "diary_material.py の無い古い家 API では動かない(4:00 の sleep が書く)" $?
mv "$WORK/diary_material.py.bak" "$API/scripts/diary_material.py"
reset
OUT=$(env PETIT_HOUSE_TABLE= PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" --diary 2>/dev/null)
! grep -q "DRY RUN" <<< "$OUT" && grep -q "家の表が無いので" <<< "$(log)"
check "家の表が無い環境では動かない" $?

# 3. いつもの回は変わらない(--diary を渡さず、日記は夜の回でと言う)
echo '{"active_hours": [[0, 24]]}' > "$CHAR/config/settings.json"
reset
OUT=$(env PETIT_HOUSE_TABLE=t PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" 2>/dev/null)
! grep -q -- "--diary" "$FAKE_PY_CALLS" && ! grep -q "diary_material.py" "$FAKE_PY_CALLS" && grep -q "\[SOURCE=autonomous\]" <<< "$OUT"
check "cron の回は --diary を渡さず、材料も読まない" $?
grep -q "日記は夜(20 時半ごろ)の「今日をふり返る回」に、その日の会話と出来事を見返して自分で書く(house の diary_write)ので、ここでは書かない" <<< "$OUT"
check "いつもの回のプロンプトに「日記は夜の回で自分で書く。ここでは書かない」" $?
reset
OUT=$(env PETIT_HOUSE_TABLE=t FAKE_MAINT_PAUSE=1 PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" 2>/dev/null)
grep -q "maintenance_state.py" "$FAKE_PY_CALLS" && ! grep -q "DRY RUN" <<< "$OUT"
check "いつもの回はメンテナンス(ぷちも休ませる)で休む" $?
reset
OUT=$(env PETIT_HOUSE_TABLE=t FAKE_MAINT_PAUSE=1 PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" --diary 2>/dev/null)
grep -q "## 今日の材料" <<< "$OUT"
check "今日をふり返る回はメンテナンスでも動く(日記は止めない)" $?

# 4. 本番の形: 台帳の source・日記を書いたかのログ
reset
run PETIT_HOUSE_TABLE=t FAKE_CLAUDE_WROTE=1 "$BASH" "$SCRIPT" mio --date "$DATE" --diary
[ -s "$FAKE_CLAUDE_CALLS" ]; check "claude を呼ぶ" $?
grep -q "record_usage.py --petit mio --source diary" "$FAKE_PY_CALLS" && grep -q "archive_stream.py --petit mio --source diary" "$FAKE_PY_CALLS"
check "台帳・全文ログの source は diary" $?
grep -qF "[09:00] なぎ: おはよう" "$FAKE_CLAUDE_PROMPT"; check "claude に材料が渡る" $?
grep -q "\[diary\] 日記を書いた(diary_write/diary_append を呼んだ)" <<< "$(log)"; check "diary_write を呼んだとログに残す" $?
! grep -q "ひみつの本文" <<< "$(log)"; check "ログに日記の本文を残さない" $?
! grep -q "おはよう" <<< "$(log)"; check "ログに材料の中身を残さない" $?
[ -f "$CHAR/state/.heartbeat-session-id" ]; check "いつもの自律行動と同じセッションを続ける(session_id を残す)" $?
reset
run PETIT_HOUSE_TABLE=t "$BASH" "$SCRIPT" mio --date "$DATE" --diary
grep -q "\[diary\] 日記を書かなかった" <<< "$(log)"; check "diary_write を呼ばなかった日はそう残す(4:00 の sleep が書く)" $?

# 5. 重ならないように(flock): 前の回が動いていれば待つ。待ちきれなければ抜ける
if command -v flock > /dev/null 2>&1; then
  reset
  flock "$LOCK" sleep 3 & HOLDER=$!; sleep 0.5
  run PETIT_HOUSE_TABLE=t PETIT_DIARY_LOCK_WAIT_S=1 "$BASH" "$SCRIPT" mio --date "$DATE" --diary
  [ ! -s "$FAKE_CLAUDE_CALLS" ] && grep -q "今日をふり返る回は動かない" <<< "$(log)"
  check "待ちきれなければ、今日をふり返る回は抜ける" $?
  wait "$HOLDER"
  reset
  flock "$LOCK" sleep 2 & HOLDER=$!; sleep 0.5
  run PETIT_HOUSE_TABLE=t PETIT_DIARY_LOCK_WAIT_S=20 "$BASH" "$SCRIPT" mio --date "$DATE" --diary
  [ -s "$FAKE_CLAUDE_CALLS" ]; check "前の回が終われば、今日をふり返る回はそのあと動く" $?
  wait "$HOLDER"
else
  echo "skip flock が無い(重ならないようにの確かめは Linux / WSL で)"
fi

if [ "$fails" -gt 0 ]; then echo "$fails 件失敗"; exit 1; fi
echo "すべて通った"
