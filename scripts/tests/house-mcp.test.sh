#!/usr/bin/env bash
# 家の道具 MCP（house・2026-09-27）の載せ方を確かめる。
# - gen-mcp-config.sh: 家 API に house_mcp.py があるときだけ mcpServers.house を書き、env は PETIT_ID・PETIT_DATA_DIR だけ
# - autonomous-action.sh: allowedTools に mcp__house__* が入る（--dry-run で止める）
# claude・AWS・Docker には触らない。
#
# Usage: bash scripts/tests/house-mcp.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
mkdir -p "$PETIT_DATA_DIR/characters/mio/config" "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin" "$PETIT_MCP_DIR"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# 1. house_mcp.py が無い家 API（古い版）では載せない
bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e '.mcpServers | has("house") | not' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "house_mcp.py が無ければ house を載せない" $?

# 2. あれば載せる（焼き込み済みの venv の実行ファイルを直接使う）
echo '# placeholder' > "$PETIT_REPOS_DIR/m5-petit-app/house_mcp.py"
printf '#!/bin/sh\n' > "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/petit-house-mcp"
chmod +x "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/petit-house-mcp"
PETIT_HOUSE_TABLE=secret-table bash "$HERE/gen-mcp-config.sh" mio > /dev/null
jq -e --arg c "$PETIT_REPOS_DIR/m5-petit-app/.venv/bin/petit-house-mcp" \
  '.mcpServers.house.command == $c and .mcpServers.house.env.PETIT_ID == "mio"' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "house_mcp.py があれば house を載せる（PETIT_ID はそのぷち）" $?
# env に書くのは PETIT_ID・PETIT_DATA_DIR だけ（表の名前・秘密はコンテナの env から届く）
jq -e '.mcpServers.house.env | keys == ["PETIT_DATA_DIR", "PETIT_ID"]' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "house の env は PETIT_ID・PETIT_DATA_DIR だけ" $?
# ほかの MCP は変わらず載る
jq -e '.mcpServers | has("memory") and has("petit-sns")' "$PETIT_MCP_DIR/mio.json" > /dev/null
check "memory・petit-sns はそのまま" $?

# 3. 自律行動の allowedTools に house の道具が入る
rm -rf "$PETIT_DATA_DIR/logs"
PETIT_HOUSE_TABLE= bash "$HERE/autonomous-action.sh" mio --dry-run > /dev/null 2>&1
log="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
for t in note_list note_read note_write note_tag note_delete mail_read mail_send relation_list relation_update relation_clear; do
  grep -qx "mcp__house__$t" <<<"$log"
  check "allowedTools に mcp__house__$t" $?
done

# 4. 体・アルバム・視覚の記憶の道具（2026-09-29・#171 H6）。クラウドに無い m5-mcp は許可しない
for t in mcp__house__body_wait_touch mcp__house__body_glance mcp__house__body_speak \
         mcp__house__album_list mcp__house__album_look mcp__house__album_mark_seen mcp__memory__save_visual_memory; do
  grep -qx "$t" <<<"$log"
  check "allowedTools に $t" $?
done
! grep -q "^mcp__m5-mcp__" <<<"$log"
check "キャラ固有の設定に m5-mcp が無ければ m5-mcp の道具は許可しない" $?
grep -q "声(body_speak)は、声で伝えたいと思った言葉があるときだけ" <<<"$log"
check "声はぷちが選んだ言葉だけ、とプロンプトに書く" $?

# 5. ローカル版（キャラ固有の設定に m5-mcp がある）では m5-mcp の道具も許可する
echo '{"mcpServers": {"m5-mcp": {"command": "true"}}}' > "$PETIT_DATA_DIR/characters/mio/config/autonomous-mcp.json"
rm -rf "$PETIT_DATA_DIR/logs"
PETIT_HOUSE_TABLE= bash "$HERE/autonomous-action.sh" mio --dry-run > /dev/null 2>&1
log="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
grep -qx "mcp__m5-mcp__show_face" <<<"$log" && grep -qx "mcp__m5-mcp__take_snapshot" <<<"$log"
check "m5-mcp があるキャラには m5-mcp の道具も許可する" $?
rm -f "$PETIT_DATA_DIR/characters/mio/config/autonomous-mcp.json"

# 6. カメラ・スピーカーを止めていれば、目・声の道具は許可しない
echo '{"allow_camera": false, "allow_sound": false}' > "$PETIT_DATA_DIR/characters/mio/config/settings.json"
rm -rf "$PETIT_DATA_DIR/logs"
PETIT_HOUSE_TABLE= bash "$HERE/autonomous-action.sh" mio --dry-run --force-normal > /dev/null 2>&1
log="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
! grep -qx "mcp__house__body_glance" <<<"$log" && ! grep -qx "mcp__house__body_gaze" <<<"$log" \
  && ! grep -qx "mcp__house__body_speak" <<<"$log"
check "カメラ・スピーカーが止まっていれば body_glance・body_gaze・body_speak を許可しない" $?
grep -qx "mcp__house__body_face" <<<"$log" && grep -qx "mcp__house__album_look" <<<"$log"
check "止めていない道具（顔・アルバム）はそのまま" $?
rm -f "$PETIT_DATA_DIR/characters/mio/config/settings.json"

if [ "$fails" -gt 0 ]; then echo "$fails 件失敗"; exit 1; fi
echo "すべて ok"
