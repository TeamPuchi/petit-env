#!/usr/bin/env bash
# CHARACTER_IDS(カンマ区切り)の各キャラに対して、指定したジョブを順に実行する。
#
# supercronicのcrontab(cron/petit.cron)から呼ばれる想定。キャラごとに個別のcron行を
# 書く代わりに、この1本の窓口スクリプトがCHARACTER_IDS環境変数を動的に展開する。
#
# Usage:
#   run-for-each-character.sh <autonomous|desire|memory-sleep|experience-watchdog>
set -u

JOB="${1:-}"
if [ -z "$JOB" ]; then
  echo "Usage: $0 <autonomous|desire|memory-sleep|experience-watchdog>" >&2
  exit 1
fi

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
REPOS_DIR="/opt/petit/repos"

IFS=',' read -ra CHARS <<< "${CHARACTER_IDS:-}"
if [ "${#CHARS[@]}" -eq 0 ] || [ -z "${CHARS[0]}" ]; then
  echo "[run-for-each-character] CHARACTER_IDS が未設定。何もしない。" >&2
  exit 0
fi

for c in "${CHARS[@]}"; do
  CHARACTER_ID="$(echo "$c" | xargs)"
  [ -z "$CHARACTER_ID" ] && continue

  case "$JOB" in
    autonomous)
      /opt/petit/scripts/autonomous-action.sh "$CHARACTER_ID"
      ;;
    desire)
      if [ -f "$REPOS_DIR/petit-desire/desire_updater.py" ]; then
        (
          cd "$REPOS_DIR/petit-desire" && \
          PETIT_DATA_DIR="$PETIT_DATA_DIR" uv run python desire_updater.py "$CHARACTER_ID"
        )
      else
        echo "[run-for-each-character] $REPOS_DIR/petit-desire が未同期。desireスキップ (character=$CHARACTER_ID)" >&2
      fi
      ;;
    memory-sleep)
      if [ -f "$REPOS_DIR/petit-memory/scripts/sleep.py" ]; then
        (
          cd "$REPOS_DIR/petit-memory" && \
          MEMORY_DB_PATH="$PETIT_DATA_DIR/characters/$CHARACTER_ID/memory.db" uv run python scripts/sleep.py
        )
      else
        echo "[run-for-each-character] $REPOS_DIR/petit-memory が未同期。memory-sleepスキップ (character=$CHARACTER_ID)" >&2
      fi
      ;;
    experience-watchdog)
      /opt/petit/scripts/experience-watchdog.sh "$CHARACTER_ID"
      ;;
    *)
      echo "Unknown job: $JOB" >&2
      exit 1
      ;;
  esac
  sleep 2  # キャラ間で少しずらす(同時起動によるリソース競合を緩和)
done
