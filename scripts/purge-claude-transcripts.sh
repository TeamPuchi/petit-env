#!/usr/bin/env bash
# claude CLI がぷちコンテナの中に残す会話記録を、24時間より古いものから消す（K21・2026-09-24）。
#
#   purge-claude-transcripts.sh [時間(分)。既定 1440]
#
# 記憶は記憶 MCP（petit-memory。忘れる＝鍵ごと消す）が持つので、claude 側の会話記録は残さない方針。
# ここに残ると、記憶で「忘れた」ことが会話の生の記録から読めてしまう。
# supercronic が毎日呼ぶ（cron/petit.cron）。置き場 ~/.claude はボリューム（petit-claude-auth-<pid>）なので、
# コンテナを作り直しても残る——だから消すのはここでやる。
#
# 消すもの（CLAUDE_CONFIG_DIR、無ければ ~/.claude の下）:
#   projects/        セッションの記録（*.jsonl）。--resume 中の会話は毎回書かれるので mtime が新しく、消えない
#   todos/ shell-snapshots/ file-history/ debug/ session-env/   セッションに付く作業の残り
#   history.jsonl    打ち込んだ文の履歴。1本に追記され続けるので、行の timestamp で古い行だけ落とす
# 消さないもの: .credentials.json（claude login の認証）・settings*.json・その他の設定。
set -euo pipefail

MINUTES="${1:-1440}"
[[ "$MINUTES" =~ ^[0-9]+$ ]] || { echo "[purge-claude] 分は数字で: $MINUTES" >&2; exit 1; }
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[[ -d "$CLAUDE_DIR" ]] || { echo "[purge-claude] $CLAUDE_DIR が無い。何もしない"; exit 0; }

removed=0
for sub in projects todos shell-snapshots file-history debug session-env; do
  dir="$CLAUDE_DIR/$sub"
  [[ -d "$dir" ]] || continue
  n="$(find "$dir" -type f -mmin "+$MINUTES" -print -delete | wc -l)"
  removed=$((removed + n))
  # 空になったディレクトリ（セッションごと・プロジェクトごと）も片づける。置き場そのものは残す
  find "$dir" -mindepth 1 -type d -empty -delete
done

history="$CLAUDE_DIR/history.jsonl"
if [[ -f "$history" ]]; then
  if command -v jq >/dev/null 2>&1; then
    cutoff_ms=$(( ($(date +%s) - MINUTES * 60) * 1000 ))
    tmp="$(mktemp "$history.XXXXXX")"
    # timestamp（ミリ秒）の無い行・読めない行も残さない
    jq -c -R --argjson c "$cutoff_ms" 'fromjson? | select((.timestamp | type) == "number" and .timestamp >= $c)' \
      "$history" > "$tmp" 2>/dev/null || : > "$tmp"
    before="$(wc -l < "$history")"
    after="$(wc -l < "$tmp")"
    chmod --reference="$history" "$tmp" 2>/dev/null || true
    mv "$tmp" "$history"
    removed=$((removed + before - after))
  elif [[ -n "$(find "$history" -mmin "+$MINUTES")" ]]; then
    rm -f "$history"
    removed=$((removed + 1))
  fi
fi

echo "[purge-claude] $(date -Iseconds) $CLAUDE_DIR から ${MINUTES} 分より古い会話記録を消した（${removed} 件）"
