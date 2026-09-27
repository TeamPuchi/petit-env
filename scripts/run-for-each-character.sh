#!/usr/bin/env bash
# CHARACTER_IDS(カンマ区切り)の各キャラに対して、指定したジョブを順に実行する。
#
# supercronicのcrontab(cron/petit.cron)から呼ばれる想定。キャラごとに個別のcron行を
# 書く代わりに、この1本の窓口スクリプトがCHARACTER_IDS環境変数を動的に展開する。
#
# Usage:
#   run-for-each-character.sh <autonomous|desire|diary|memory-sleep|experience-watchdog>
set -u

JOB="${1:-}"
if [ -z "$JOB" ]; then
  echo "Usage: $0 <autonomous|desire|diary|memory-sleep|experience-watchdog>" >&2
  exit 1
fi

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
REPOS_DIR="${PETIT_REPOS_DIR:-/opt/petit/repos}"

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
      if [ -f "$REPOS_DIR/petit-desire/pyproject.toml" ]; then
        # 欲求 MCP（desire-system）と同じ置き場を見る。gen-mcp-config.sh が作った env をそのまま使う
        # （家の表 STATE#DESIRES か desires.json か・記憶の置き場の決め方を1か所にするため。memory-sleep と同じ）。
        MCP_JSON="${PETIT_MCP_DIR:-/opt/petit/run/mcp}/$CHARACTER_ID.json"
        [ -f "$MCP_JSON" ] || /opt/petit/scripts/gen-mcp-config.sh "$CHARACTER_ID" >&2
        mapfile -t DESIRE_ENV < <(jq -r '.mcpServers["desire-system"].env // {} | to_entries[] | "\(.key)=\(.value)"' "$MCP_JSON" 2>/dev/null | tr -d '\r')
        if [ "${#DESIRE_ENV[@]}" -eq 0 ]; then
          DESIRE_ENV=("CHARACTER_ID=$CHARACTER_ID" "PETIT_DATA_DIR=$PETIT_DATA_DIR")
        fi
        if [ -x "$REPOS_DIR/petit-desire/.venv/bin/desire-updater" ]; then
          DESIRE_CMD=("$REPOS_DIR/petit-desire/.venv/bin/desire-updater")   # 焼き込み済み
        else
          DESIRE_CMD=(uv run --directory "$REPOS_DIR/petit-desire" desire-updater)   # dev
        fi
        # 表・SNS が詰まっても次の回（5分後）と重ならないよう打ち切る（autonomous-action.sh の desire-status と同じ形）
        env "${DESIRE_ENV[@]}" timeout 60 "${DESIRE_CMD[@]}" "$CHARACTER_ID"
      else
        echo "[run-for-each-character] $REPOS_DIR/petit-desire が未同期。desireスキップ (character=$CHARACTER_ID)" >&2
      fi
      ;;
    diary)
      # ぷちが寝る(akatsuki-petit#133): きのう(JST)の会話と記憶を見返して日記を書き(DIARY#<date>)、
      # 会話のセッションを切る。書くのは家 API の scripts/write_diary.py(ぷちの SOUL.md の口調で claude を呼ぶ)。
      # 家の表が無い環境(PETIT_HOUSE_TABLE 未設定)・write_diary.py の無い古い家 API では何もしない。
      HOUSE_API_DIR="$REPOS_DIR/m5-petit-app"
      WRITE_DIARY="$HOUSE_API_DIR/scripts/write_diary.py"
      if [ -z "${PETIT_HOUSE_TABLE:-}" ]; then
        echo "[run-for-each-character] PETIT_HOUSE_TABLE が未設定。diaryスキップ (character=$CHARACTER_ID)" >&2
      elif [ ! -f "$WRITE_DIARY" ]; then
        echo "[run-for-each-character] $WRITE_DIARY が無い。diaryスキップ (character=$CHARACTER_ID)" >&2
      else
        if [ -x "$HOUSE_API_DIR/.venv/bin/python" ]; then
          HOUSE_PY=("$HOUSE_API_DIR/.venv/bin/python")            # 焼き込み済み
        else
          HOUSE_PY=(uv run --directory "$HOUSE_API_DIR" python)   # dev
        fi
        # 標準出力は1行(日付と結果だけ。日記の本文は出さない)。claude が詰まっても次のキャラへ進めるよう打ち切る
        echo "[diary] $(date -Iseconds) $CHARACTER_ID: $(timeout 300 "${HOUSE_PY[@]}" "$WRITE_DIARY" "$CHARACTER_ID" 2>&1 | tail -n 1)"
      fi
      ;;
    memory-sleep)
      if [ -f "$REPOS_DIR/petit-memory/scripts/sleep.py" ]; then
        # 記憶 MCP と同じ置き場(sqlite/dynamo・表名・pid)を見る。gen-mcp-config.sh が作った
        # memory の env をそのまま使う(置き場の決め方を1か所にするため・K14)。
        MCP_JSON="${PETIT_MCP_DIR:-/opt/petit/run/mcp}/$CHARACTER_ID.json"
        [ -f "$MCP_JSON" ] || /opt/petit/scripts/gen-mcp-config.sh "$CHARACTER_ID" >&2
        mapfile -t MEMORY_ENV < <(jq -r '.mcpServers.memory.env // {} | to_entries[] | "\(.key)=\(.value)"' "$MCP_JSON" 2>/dev/null)
        if [ -x "$REPOS_DIR/petit-memory/.venv/bin/python" ]; then
          MEMORY_PY=("$REPOS_DIR/petit-memory/.venv/bin/python")   # 焼き込み済み(CPU 版 torch)
        else
          MEMORY_PY=(uv run python)                               # dev
        fi
        (
          cd "$REPOS_DIR/petit-memory" && \
          env "${MEMORY_ENV[@]}" "${MEMORY_PY[@]}" scripts/sleep.py
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
