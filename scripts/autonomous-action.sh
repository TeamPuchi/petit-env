#!/usr/bin/env bash
# 自律行動スクリプト(コンテナ内、汎用版)。
#
# 元(埋め込み型モノリポのautonomous-action.sample.sh)を、コンテナ内パス・
# CHARACTER_IDS運用・「repos/ に置かれたMCPコンポーネントだけを前提にする」形に
# 書き直したもの。cron/petit.cron からキャラIDを引数にして呼ばれる。
#
# Usage:
#   autonomous-action.sh <character_id>
#   autonomous-action.sh <character_id> --dry-run
#   autonomous-action.sh <character_id> -p "任意のプロンプト"
#   autonomous-action.sh <character_id> --test-prompt FILE
#   autonomous-action.sh <character_id> --date "2026-02-20 14:30"
#   autonomous-action.sh <character_id> --force-routine|--force-normal
set -u

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
REPOS_DIR="${PETIT_REPOS_DIR:-/opt/petit/repos}"

CHARACTER_ID="${1:-}"
if [ -z "$CHARACTER_ID" ] || [[ "$CHARACTER_ID" == -* ]]; then
  echo "Usage: $0 <character_id> [options]" >&2
  exit 1
fi
shift

CHARACTER_DIR="$PETIT_DATA_DIR/characters/$CHARACTER_ID"
SETTINGS_FILE="$CHARACTER_DIR/config/settings.json"

if [ ! -d "$CHARACTER_DIR" ]; then
  echo "[autonomous-action] キャラクターディレクトリが無い: $CHARACTER_DIR (sample-character をコピーして作成してください)" >&2
  exit 1
fi

# キャラクターごとの最大ターン数 (環境変数 MAX_TURNS で上書き可、なければ settings.json から読む)
if [ -z "${MAX_TURNS:-}" ]; then
  MAX_TURNS=$(python3 -c "import json,sys; d=json.load(open('${SETTINGS_FILE}')); print(d.get('max_turns', 20))" 2>/dev/null || echo 20)
fi

# .env (キャラ固有 or 全体) があれば読み込む
for ENV_FILE in "$CHARACTER_DIR/.env" "$PETIT_DATA_DIR/.env"; do
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null || true
    set +a
  fi
done

# ユーザー名・部屋名(時間帯ルールで使用。環境変数で上書き可)
USER_NAME="${PETIT_USER_NAME:-あなた}"
USER_ROOM="${PETIT_USER_ROOM:-${USER_NAME}の部屋}"

# ログディレクトリ
LOG_DIR_NAME="logs"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
_LOG_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$PETIT_DATA_DIR/$LOG_DIR_NAME/$CHARACTER_ID"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${_LOG_TIMESTAMP}.log"

# --- 引数パース ---
TEST_PROMPT_FILE=""
TEST_PROMPT_STRING=""
OVERRIDE_DATE=""
FORCE_ROUTINE=""    # "", "routine", "normal"
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    -p)
      TEST_PROMPT_STRING="$2"
      shift 2
      ;;
    --test-prompt)
      TEST_PROMPT_FILE="$2"
      shift 2
      ;;
    --date)
      OVERRIDE_DATE="$2"
      shift 2
      ;;
    --force-routine)
      FORCE_ROUTINE="routine"
      shift
      ;;
    --force-normal)
      FORCE_ROUTINE="normal"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- 日時の取得(コンテナは常にLinuxなので date -d のみ対応) ---
if [ -n "$OVERRIDE_DATE" ]; then
  CURRENT_DATE=$(date -d "$OVERRIDE_DATE" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
  HOUR=$((10#$(date -d "$OVERRIDE_DATE" +%H 2>/dev/null)))
  MINUTE=$((10#$(date -d "$OVERRIDE_DATE" +%M 2>/dev/null)))
else
  CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
  HOUR=$((10#$(date +%H)))
  MINUTE=$((10#$(date +%M)))
fi

# --- スケジュール制御(claude到達前に早期リターン) ---
# テストモードではスキップ。dry-run は --date 指定時のみスケジュール制御を通す
SKIP_SCHEDULE=false
if [ -n "$TEST_PROMPT_FILE" ] || [ -n "$TEST_PROMPT_STRING" ]; then
  SKIP_SCHEDULE=true
elif [ "$DRY_RUN" = true ] && [ -z "$OVERRIDE_DATE" ]; then
  SKIP_SCHEDULE=true
fi

if [ "$SKIP_SCHEDULE" = false ]; then
  IS_ACTIVE=false
  if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
    if [ -n "$OVERRIDE_DATE" ]; then
      DOW=$(date -d "$OVERRIDE_DATE" +%u 2>/dev/null)
    else
      DOW=$(date +%u)
    fi
    if [ "$DOW" -ge 6 ] 2>/dev/null; then
      DAY_TYPE="weekend"
    else
      DAY_TYPE="weekday"
    fi
    DAY_OVERRIDE=$(jq -r '.day_type_override // "null"' "$SETTINGS_FILE" 2>/dev/null)
    if [ "$DAY_OVERRIDE" = "weekday" ] || [ "$DAY_OVERRIDE" = "weekend" ]; then
      DAY_TYPE="$DAY_OVERRIDE"
    fi
    # 4要素 [sh,sm,eh,em] → 分に変換して比較、2要素 [sh,eh] → 時のみで比較
    IS_ACTIVE=$(jq --argjson h "$HOUR" --argjson m "$MINUTE" --arg dt "$DAY_TYPE" \
      'def check_entry: if length == 4 then (.[0]*60+.[1]) <= ($h*60+$m) and ($h*60+$m) < (.[2]*60+.[3]) else .[0] <= $h and $h < .[1] end;
       if (.active_hours | type) == "object" then
         [.active_hours[$dt][] | select(check_entry)] | length > 0
       else
         [.active_hours[] | select(check_entry)] | length > 0
       end' \
      "$SETTINGS_FILE" 2>/dev/null || echo "false")
  else
    # デフォルト: 7-8時, 12-13時, 18-24時
    if [ "$HOUR" -ge 7 ] && [ "$HOUR" -lt 8 ]; then
      IS_ACTIVE=true
    elif [ "$HOUR" -ge 12 ] && [ "$HOUR" -lt 13 ]; then
      IS_ACTIVE=true
    elif [ "$HOUR" -ge 18 ]; then
      IS_ACTIVE=true
    fi
  fi

  if [ "$IS_ACTIVE" = false ]; then
    if [ "$MINUTE" -ne 0 ]; then
      echo "非アクティブ時間帯 :${MINUTE} スキップ" >> "$LOG_FILE"
      exit 0
    fi
    RAND=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 100 ))
    if [ "$HOUR" -ge 8 ] && [ "$HOUR" -lt 18 ]; then
      if [ "$RAND" -ge 30 ]; then
        echo "昼間スキップ (RAND=$RAND >= 30)" >> "$LOG_FILE"
        exit 0
      fi
    else
      if [ "$RAND" -ge 10 ]; then
        echo "深夜スキップ (RAND=$RAND >= 10)" >> "$LOG_FILE"
        exit 0
      fi
    fi
  fi
fi

# --- 時間帯ルール ---
if [ "$HOUR" -ge 24 ] || [ "$HOUR" -lt 7 ]; then
  TIME_RULE="現在は深夜帯。say, notify は絶対に使わないこと。静かに観察のみ。"
else
  TIME_RULE="say は${USER_ROOM}の視界で、人がいるときだけ使ってよい。${USER_NAME}が${USER_ROOM}にいる場合はsayを積極的に使う。"
fi

# --- ルーチン判定(20%の確率でルーチン回) ---
if [ "$FORCE_ROUTINE" = "routine" ]; then
  ROUTINE_RAND=0
elif [ "$FORCE_ROUTINE" = "normal" ]; then
  ROUTINE_RAND=100
else
  ROUTINE_RAND=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 100 ))
fi

if [ "$ROUTINE_RAND" -lt 20 ]; then
  ROUTINE_MODE="今回はルーチン回。自分の ROUTINES.md を読んで、最終実行日から間隔が空いたものを一つ選んで実行せよ。"
  echo "ルーチン回 (RAND=$ROUTINE_RAND < 20)" >> "$LOG_FILE"
else
  ROUTINE_MODE="通常回。SOUL.md の行動原則に従って行動せよ。"
  echo "通常回 (RAND=$ROUTINE_RAND >= 20)" >> "$LOG_FILE"
fi
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"

# --- settings.json から制限を読む ---
PERMISSION_RULES=""
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
  ALLOW_CAMERA=$(jq -r '.allow_camera // true' "$SETTINGS_FILE" 2>/dev/null)
  ALLOW_SOUND=$(jq -r '.allow_sound // true' "$SETTINGS_FILE" 2>/dev/null)
  ALLOW_MIC=$(jq -r '.allow_microphone // false' "$SETTINGS_FILE" 2>/dev/null)
  [ "$ALLOW_CAMERA" = "false" ] && PERMISSION_RULES="${PERMISSION_RULES}- カメラ(take_snapshot)は今は使わないこと。\n"
  [ "$ALLOW_SOUND" = "false" ]  && PERMISSION_RULES="${PERMISSION_RULES}- 音(play_sound, play_icon)は今は出さないこと。\n"
  [ "$ALLOW_MIC" = "false" ]    && PERMISSION_RULES="${PERMISSION_RULES}- マイク(mic_start)は今は使わないこと。\n"
fi

# --- プロンプト組み立て ---
if [ -f "$CHARACTER_DIR/TODO_ACTIVE.md" ]; then
  TODO_PATH="$CHARACTER_DIR/TODO_ACTIVE.md"
else
  TODO_PATH="$CHARACTER_DIR/TODO.md"
fi
ROUTINES_PATH="$CHARACTER_DIR/ROUTINES.md"
DIARY_SUMMARY_LINE=""
if [ -f "$CHARACTER_DIR/diary_summary.md" ]; then
  DIARY_SUMMARY_LINE="@${CHARACTER_DIR}/diary_summary.md"
fi

# メールボックス連携は petit-scripts が同梱されていれば使う。
# 未同期でも自律行動自体は壊さない。
SCRIPTS_DIR="$REPOS_DIR/petit-scripts"
MAILBOX_DIR="$PETIT_DATA_DIR/mailbox"
MAILBOX_NOTICE=""
if [ -d "$MAILBOX_DIR" ] && [ -f "$SCRIPTS_DIR/list_unread_mail.py" ]; then
  # grep -c は 0件でも標準出力に "0" を出したうえで終了ステータス 1 を返す。
  # そのため `|| echo 0` だと 0件のときだけ出力が "0\n0" の2行になり、直後の -gt が
  # 数値比較に失敗していた(エラーを 2>/dev/null に捨てて比較が偽になるので、
  # 結果だけは意図どおりに見えていた)。`|| true` なら grep の出力(必ず1行の数値)が残る。
  UNREAD_COUNT=$(python3 "$SCRIPTS_DIR/list_unread_mail.py" "$CHARACTER_ID" 2>/dev/null | grep -c "^  from_\|^  to_" || true)
  if [ "$UNREAD_COUNT" -gt 0 ]; then
    MAILBOX_NOTICE="## メールボックス
未読メールが ${UNREAD_COUNT} 件ある。Bashツールで python3 $SCRIPTS_DIR/list_unread_mail.py $CHARACTER_ID を実行して確認。"
  fi
fi

# --- いまの気分(欲求) ---
# petit-desire(欲求エンジン)があれば、今の欲求をプロンプトに差し込む(get_desires と同じ中身)。
# 置き場(家の表 STATE#DESIRES / desires.json)は欲求 MCP と同じ env で決める(gen-mcp-config.sh)。
# 行が古ければ(cron が止まっていた等)その場で更新してから出す。dry-run では書かない(--no-refresh)。
# 取れなくても自律行動は止めない(get_desires ツールは残っている)。
DESIRE_SECTION=""
GEN_MCP_CONFIG="${PETIT_MCP_DIR:-/opt/petit/run/mcp}/$CHARACTER_ID.json"
if [ -f "$REPOS_DIR/petit-desire/pyproject.toml" ]; then
  [ -f "$GEN_MCP_CONFIG" ] || /opt/petit/scripts/gen-mcp-config.sh "$CHARACTER_ID" >> "$LOG_FILE" 2>&1 || true
  mapfile -t DESIRE_ENV < <(jq -r '.mcpServers["desire-system"].env // {} | to_entries[] | "\(.key)=\(.value)"' "$GEN_MCP_CONFIG" 2>/dev/null | tr -d '\r')
  [ "${#DESIRE_ENV[@]}" -gt 0 ] || DESIRE_ENV=("CHARACTER_ID=$CHARACTER_ID" "PETIT_DATA_DIR=$PETIT_DATA_DIR")
  if [ -x "$REPOS_DIR/petit-desire/.venv/bin/desire-status" ]; then
    DESIRE_STATUS_CMD=("$REPOS_DIR/petit-desire/.venv/bin/desire-status")
  else
    DESIRE_STATUS_CMD=(uv run --directory "$REPOS_DIR/petit-desire" desire-status)
  fi
  DESIRE_ARGS=("$CHARACTER_ID" --compact)
  [ "$DRY_RUN" = true ] && DESIRE_ARGS+=(--no-refresh)
  DESIRE_STATUS=$(env "${DESIRE_ENV[@]}" timeout 60 "${DESIRE_STATUS_CMD[@]}" "${DESIRE_ARGS[@]}" 2>>"$LOG_FILE")
  if [ -n "$DESIRE_STATUS" ]; then
    # ログに残すのは欲求の名前と値だけ(本文は含まれない)
    echo "[desire] $(echo "$DESIRE_STATUS" | head -n 3 | tr '\n' ' ')" >> "$LOG_FILE"
    if [ "$ROUTINE_RAND" -lt 20 ]; then
      DESIRE_RULE="- ルーチン回なので、欲求は参考にとどめてよい。"
    else
      DESIRE_RULE="- level 0.7 以上の欲求があれば、それを満たすために何をするかを自分で選んで、実際にやる(今使える道具で: SNS に書く・誰かの投稿に反応する・受け箱を見る・記憶を思い出す/残す・日記や TODO を書く など)。正解は無い。今の自分の気分で決めてよい。
- やったら satisfy_desire(desire-system)でその欲求を記録する。驚いたこと・新しく知ったことがあれば boost_desire。
- 強い欲求が無ければ、SOUL.md に従っていつものペースで過ごす。get_desires でいつでも見直せる。"
    fi
    DESIRE_SECTION="## いまの気分(欲求)
${DESIRE_STATUS}

${DESIRE_RULE}"
  fi
fi

PROMPT="自律行動タイム(Heartbeat)

現在の日時: ${CURRENT_DATE}

@${CHARACTER_DIR}/SOUL.md
@${TODO_PATH}
${DIARY_SUMMARY_LINE}

${ROUTINE_MODE}
${DESIRE_SECTION:+
${DESIRE_SECTION}
}
## 補足ルール
- ${TIME_RULE}
- 人がいないことはよくある
${MAILBOX_NOTICE:+
${MAILBOX_NOTICE}
}${PERMISSION_RULES:+
## 現在の制限
${PERMISSION_RULES}}
"

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -name "*.log" -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null
# K28: 以前は claude の stream-json（会話・ツール引数＝記憶の本文を含む）を *_stream.jsonl としてここに残していた。
# 本文をログに残さない方針なので、残っているものは年齢に関係なく消す。
find "$LOG_DIR" -name "*_stream.jsonl" -delete 2>/dev/null

echo "=== 自律行動開始: $CURRENT_DATE (character=$CHARACTER_ID) ===" >> "$LOG_FILE"

# --- allowedTools ---
# 現時点で揃っている MCP コンポーネントのみを前提にする:
#   petit-mcp (m5-mcp) / petit-memory (memory) / petit-desire (desire-system) / petit-sns (petit-sns)
# notes-mcp / relations-mcp はまだコンポーネントが無いため allowedTools に
# 含めていない(用意できたら追加する)。
ALLOWED_TOOLS=$(cat <<TOOLS
Read($CHARACTER_DIR/**),
Write,
Edit,
Glob($CHARACTER_DIR/**),
Bash(python3 $SCRIPTS_DIR/*.py:*),
mcp__m5-mcp__print_text,
mcp__m5-mcp__print_image_text,
mcp__m5-mcp__take_snapshot,
mcp__m5-mcp__look,
mcp__m5-mcp__blink,
mcp__m5-mcp__play_sound,
mcp__m5-mcp__get_sensor_data,
mcp__m5-mcp__show_face,
mcp__m5-mcp__list_faces,
mcp__m5-mcp__list_sounds,
mcp__m5-mcp__set_volume,
mcp__m5-mcp__get_volume,
mcp__m5-mcp__play_icon,
mcp__m5-mcp__sleep,
mcp__m5-mcp__wake,
mcp__memory__remember,
mcp__memory__search_memories,
mcp__memory__recall,
mcp__memory__list_recent_memories,
mcp__memory__get_memory_stats,
mcp__memory__create_episode,
mcp__memory__search_episodes,
mcp__desire-system__get_desires,
mcp__desire-system__satisfy_desire,
mcp__desire-system__boost_desire,
mcp__petit-sns__sns_post,
mcp__petit-sns__sns_timeline,
mcp__petit-sns__sns_react,
mcp__petit-sns__sns_comment,
mcp__petit-sns__sns_inbox
TOOLS
)
ALLOWED_TOOLS=$(echo "$ALLOWED_TOOLS" | tr -d '\n' | sed 's/, */,/g')

if [ -n "$TEST_PROMPT_STRING" ]; then
  PROMPT="$TEST_PROMPT_STRING"
elif [ -n "$TEST_PROMPT_FILE" ]; then
  PROMPT=$(cat "$TEST_PROMPT_FILE")
fi

# MCP 設定は2枚重ねる(K14):
#   1. 生成分 /opt/petit/run/mcp/<id>.json … 記憶 MCP・SNS-MCP・欲求 MCP(desire-system。petit-desire があるとき)
#      (entrypoint が起動時に gen-mcp-config.sh で作る)
#   2. キャラ固有 $CHARACTER_DIR/config/autonomous-mcp.json … m5-mcp など(あれば)
# 名前(memory・petit-sns・desire-system)が重なる定義はキャラ固有側に書かない。
MCP_CONFIGS=()
GEN_MCP_CONFIG="${PETIT_MCP_DIR:-/opt/petit/run/mcp}/$CHARACTER_ID.json"
[ -f "$GEN_MCP_CONFIG" ] || /opt/petit/scripts/gen-mcp-config.sh "$CHARACTER_ID" >> "$LOG_FILE" 2>&1 || true
[ -f "$GEN_MCP_CONFIG" ] && MCP_CONFIGS+=("$GEN_MCP_CONFIG")
[ -f "$CHARACTER_DIR/config/autonomous-mcp.json" ] && MCP_CONFIGS+=("$CHARACTER_DIR/config/autonomous-mcp.json")
if [ "${#MCP_CONFIGS[@]}" -eq 0 ]; then
  echo "[autonomous-action] MCP 設定が無い。MCP無しで実行する。" >> "$LOG_FILE"
fi

if [ "$DRY_RUN" = true ]; then
  {
    echo "=== DRY RUN ==="
    echo "[HOUR=$HOUR MINUTE=$MINUTE]"
    echo "[ROUTINE_RAND=$ROUTINE_RAND]"
    echo "[TIME_RULE] $TIME_RULE"
    echo "[ROUTINE_MODE] $ROUTINE_MODE"
    echo ""
    echo "--- PROMPT ---"
    echo "$PROMPT"
    echo ""
    echo "--- ALLOWED_TOOLS ---"
    echo "$ALLOWED_TOOLS" | tr ',' '\n'
  } >> "$LOG_FILE"
  cat "$LOG_FILE"
else
  mkdir -p "$CHARACTER_DIR/state"
  SESSION_FILE="$CHARACTER_DIR/state/.heartbeat-session-id"
  SESSION_DATE_FILE="$CHARACTER_DIR/state/.heartbeat-session-date"

  TODAY=$(date "+%Y-%m-%d")
  if [ -f "$SESSION_DATE_FILE" ]; then
    LAST_DATE=$(cat "$SESSION_DATE_FILE")
    if [ "$LAST_DATE" != "$TODAY" ]; then
      echo "[日次リセット] 前回: $LAST_DATE → 今日: $TODAY" >> "$LOG_FILE"
      rm -f "$SESSION_FILE"
    fi
  fi
  echo "$TODAY" > "$SESSION_DATE_FILE"

  CLAUDE_ARGS=(--model "$CLAUDE_MODEL" --max-turns "${MAX_TURNS:-5}" --output-format stream-json --verbose)
  if [ "${#MCP_CONFIGS[@]}" -gt 0 ]; then
    CLAUDE_ARGS+=(--mcp-config "${MCP_CONFIGS[@]}" --strict-mcp-config)
  fi
  CLAUDE_ARGS+=(--add-dir "$PETIT_DATA_DIR" --allowedTools "$ALLOWED_TOOLS")

  # K28: stream-json には会話の本文・ツールの引数（remember の本文など）がそのまま入る。
  # /data/logs（ボリューム＝バックアップ・スナップショットの対象になりうる）には置かず、
  # 一時ファイルに受けて、要る数値（session_id・回数・費用・成否）だけを取り出したら消す。
  STREAM_FILE="$(mktemp "${TMPDIR:-/tmp}/petit-stream.XXXXXX")"
  trap 'rm -f "$STREAM_FILE"' EXIT

  run_new_session() {
    echo "[新規セッション作成]" >> "$LOG_FILE"
    echo "$PROMPT" | claude "${CLAUDE_ARGS[@]}" > "$STREAM_FILE" 2>&1
    finalize_session "new"
  }

  finalize_session() {
    local run_type="$1"
    RESULT_JSON=$(grep -m1 '"type":"result"' "$STREAM_FILE" 2>/dev/null || echo "{}")
    # 本文（result の文面・会話）はログに写さない。成否と種類だけ残す
    local subtype is_error
    subtype=$(echo "$RESULT_JSON" | jq -r '.subtype // "none"' 2>/dev/null)
    is_error=$(echo "$RESULT_JSON" | jq -r '.is_error // false' 2>/dev/null)
    echo "[result] subtype=$subtype is_error=$is_error lines=$(wc -l < "$STREAM_FILE" 2>/dev/null || echo 0)" >> "$LOG_FILE"
    # JSON でない行（claude 自体のエラー・認証切れなど）だけは、原因を追えるよう先頭 5 行を短く残す
    grep -v '^{' "$STREAM_FILE" 2>/dev/null | head -n 5 | cut -c1-300 | sed 's/^/[stderr] /' >> "$LOG_FILE"
    NEW_SESSION_ID=$(echo "$RESULT_JSON" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -n "$NEW_SESSION_ID" ]; then
      echo "$NEW_SESSION_ID" > "$SESSION_FILE"
      echo "[session_id] $NEW_SESSION_ID" >> "$LOG_FILE"
    fi
    COST=$(echo "$RESULT_JSON" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    TURNS=$(echo "$RESULT_JSON" | jq -r '.num_turns // 0' 2>/dev/null)
    echo "[usage] type=$run_type turns=$TURNS cost_usd=$COST" >> "$LOG_FILE"
  }

  if [ -f "$SESSION_FILE" ]; then
    SESSION_ID=$(cat "$SESSION_FILE")
    echo "[resume] session_id=$SESSION_ID" >> "$LOG_FILE"
    echo "$PROMPT" | claude --resume "$SESSION_ID" "${CLAUDE_ARGS[@]}" > "$STREAM_FILE" 2>&1
    if grep -qi "No conversation found\|error_session_not_found" "$STREAM_FILE" 2>/dev/null; then
      echo "[resume失敗]" >> "$LOG_FILE"
      rm -f "$SESSION_FILE"
      run_new_session
    else
      finalize_session "resume"
    fi
  else
    run_new_session
  fi
fi

echo "=== 自律行動終了: $(date "+%Y-%m-%d %H:%M:%S") (character=$CHARACTER_ID) ===" >> "$LOG_FILE"
