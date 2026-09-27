#!/usr/bin/env bash
# autonomous-action.sh の「未読の手紙」の知らせを確かめる(2026-09-27)。
# 家 API の read_mailbox.py の代わりに、件数を選べる偽の python を置いて分岐だけを見る。
# - 家の表(MAIL#)の未読を read_mailbox.py <id> --unread --count で数え、あれば house の mail_read を案内する
# - 家の表が無い環境・読めないとき・0 通のときは知らせを出さず、自律行動は続ける
# - petit-scripts(ファイル式メールボックス)の Bash 許可は無い
# claude・AWS・Docker には触らない(--dry-run で止める)。
#
# Usage: bash scripts/tests/house-mail.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
export PETIT_TUTORIAL_GATE=0  # 関所は tutorial-gate.test.sh で見る
mkdir -p "$PETIT_DATA_DIR/characters/mio/config" "$PETIT_REPOS_DIR/m5-petit-app/scripts" \
         "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin" "$PETIT_MCP_DIR"
echo '# placeholder' > "$PETIT_REPOS_DIR/m5-petit-app/scripts/read_mailbox.py"
cat > "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
[ -n "${FAKE_ERR:-}" ] && { echo "boom" >&2; exit 1; }
echo "${FAKE_UNREAD:-0}"
PY
chmod +x "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/python"
export FAKE_CALLS="$WORK/calls"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
run() {  # env... → dry-run の出力(ログ)を返す
  rm -rf "$PETIT_DATA_DIR/logs"
  : > "$FAKE_CALLS"
  env "$@" bash "$SCRIPT" mio --dry-run 2>/dev/null
}

out="$(run PETIT_HOUSE_TABLE=t FAKE_UNREAD=3)"
grep -q "まだ読んでいない手紙が 3 通ある" <<<"$out" && grep -q "mail_read" <<<"$out"
check "未読があれば件数と mail_read を案内する" $?
grep -q "m5-petit-app/scripts/read_mailbox.py mio --unread --count" "$FAKE_CALLS"
check "read_mailbox.py <id> --unread --count で数える" $?
grep -q "DRY RUN" <<<"$out"
check "知らせを出しても自律行動は続く" $?

out="$(run PETIT_HOUSE_TABLE=t FAKE_UNREAD=0)"
! grep -q "## 手紙" <<<"$out" && grep -q "DRY RUN" <<<"$out"
check "0 通なら知らせない" $?

out="$(run PETIT_HOUSE_TABLE=t FAKE_ERR=1)"
! grep -q "## 手紙" <<<"$out" && grep -q "DRY RUN" <<<"$out" && grep -q "未読の手紙の件数を読めなかった" <<<"$out"
check "読めないときは知らせず、自律行動は続ける" $?

out="$(run PETIT_HOUSE_TABLE=t FAKE_UNREAD="usage: read_mailbox.py")"
! grep -q "## 手紙" <<<"$out" && grep -q "DRY RUN" <<<"$out"
check "数でない出力(--count の無い古い家 API)は知らせない" $?

out="$(run PETIT_HOUSE_TABLE= FAKE_UNREAD=3)"
! grep -q "## 手紙" <<<"$out" && grep -q "DRY RUN" <<<"$out" && [ ! -s "$FAKE_CALLS" ]
check "家の表が無い環境では数えず、自律行動は続ける" $?

# 古いファイル式メールボックス(petit-scripts)はもう見ない
mkdir -p "$PETIT_DATA_DIR/mailbox" "$PETIT_REPOS_DIR/petit-scripts"
echo 'print("  from_x")' > "$PETIT_REPOS_DIR/petit-scripts/list_unread_mail.py"
out="$(run PETIT_HOUSE_TABLE= )"
! grep -q "list_unread_mail\|petit-scripts" <<<"$out"
check "petit-scripts の list_unread_mail.py を案内しない・Bash 許可も無い" $?

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
