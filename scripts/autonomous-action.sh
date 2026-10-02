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
# W12（頭脳の原価・2026-09-30）: settings.json の値（既定 20）は PETIT_AUTONOMOUS_MAX_TURNS（既定 5）で頭打ちにする。
# 9/29〜30 の本番は 1 回平均 7.4 ターン。0 にすると頭打ちしない（前のまま）。MAX_TURNS を渡したときはそれがそのまま効く
if [ -z "${MAX_TURNS:-}" ]; then
  MAX_TURNS=$(python3 -c "import json,sys; d=json.load(open('${SETTINGS_FILE}')); print(d.get('max_turns', 20))" 2>/dev/null || echo 20)
  TURNS_CAP="${PETIT_AUTONOMOUS_MAX_TURNS:-5}"
  if [[ "$TURNS_CAP" =~ ^[0-9]+$ ]] && [ "$TURNS_CAP" -gt 0 ] && [[ "$MAX_TURNS" =~ ^[0-9]+$ ]] && [ "$MAX_TURNS" -gt "$TURNS_CAP" ]; then
    MAX_TURNS="$TURNS_CAP"
  fi
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

# --- はじめての日のチュートリアル(2026-09-27) ---
# ぷちは里親とのチュートリアル(まいぷち。の会話画面でお題に沿って話す)が済むまで自律行動しない。
# 状態は家 API と同じ house 表の STATE#TUTORIAL。判定は家 API の scripts/tutorial_state.py <id> gate:
#   0 = 達成済み → 続ける / 3 = 未完了 → 何もせず抜ける / それ以外 = 読めない → 今回は抜ける(20分後にまた見る)
# 欲求の更新(cron の desire ジョブ)はここを通らないので止まらない。
# 対象外: 手で渡すプロンプト(-p / --test-prompt)・家の表が無い環境(PETIT_HOUSE_TABLE 未設定)・
#   関所の入っていない古い家 API・PETIT_TUTORIAL_GATE=0。
HOUSE_API_DIR="$REPOS_DIR/m5-petit-app"
# 家 API の scripts/*.py を動かす python(チュートリアルの関所・未読の手紙の件数で使う)
if [ -x "$HOUSE_API_DIR/.venv/bin/python" ]; then
  HOUSE_PY=("$HOUSE_API_DIR/.venv/bin/python")                 # 焼き込み済み
else
  HOUSE_PY=(uv run --directory "$HOUSE_API_DIR" python)        # dev
fi
TUTORIAL_GATE="$HOUSE_API_DIR/scripts/tutorial_state.py"
if [ -z "$TEST_PROMPT_FILE" ] && [ -z "$TEST_PROMPT_STRING" ] && [ -n "${PETIT_HOUSE_TABLE:-}" ] \
   && [ "${PETIT_TUTORIAL_GATE:-1}" != "0" ] && [ -f "$TUTORIAL_GATE" ]; then
  TUTORIAL_OUT=$(timeout 30 "${HOUSE_PY[@]}" "$TUTORIAL_GATE" "$CHARACTER_ID" gate 2>>"$LOG_FILE")
  TUTORIAL_CODE=$?
  case "$TUTORIAL_CODE" in
    0) ;;
    3)
      echo "チュートリアル未完了のため自律行動しない ($TUTORIAL_OUT)" >> "$LOG_FILE"
      exit 0
      ;;
    *)
      echo "チュートリアルの状態を読めないので今回は自律行動しない (exit=$TUTORIAL_CODE $TUTORIAL_OUT)" >> "$LOG_FILE"
      exit 0
      ;;
  esac
fi

# --- メンテナンスモード(2026-10-02) ---
# 運営がメンテナンスモードを「ぷちの自律行動も休ませる」付きで入れているあいだ(petit-infra の
# scripts/maintenance.sh on --pause-petits)は自律行動しない。状態は accounts 表の CONFIG#maintenance / META。
# 判定は家 API の scripts/maintenance_state.py gate:
#   0 = 動いてよい → 続ける / 3 = 休む → 何もせず抜ける / それ以外 = 読めない → 続ける(普段どおり動く)
# 欲求の更新・日記・記憶の整理(cron の別ジョブ)はここを通らないので止まらない。
# 対象外: 手で渡すプロンプト(-p / --test-prompt)・家の表が無い環境(PETIT_HOUSE_TABLE 未設定)・
#   関所の入っていない古い家 API・PETIT_MAINTENANCE_GATE=0。
MAINTENANCE_GATE="$HOUSE_API_DIR/scripts/maintenance_state.py"
if [ -z "$TEST_PROMPT_FILE" ] && [ -z "$TEST_PROMPT_STRING" ] && [ -n "${PETIT_HOUSE_TABLE:-}" ]    && [ "${PETIT_MAINTENANCE_GATE:-1}" != "0" ] && [ -f "$MAINTENANCE_GATE" ]; then
  MAINTENANCE_OUT=$(timeout 30 "${HOUSE_PY[@]}" "$MAINTENANCE_GATE" gate 2>>"$LOG_FILE")
  MAINTENANCE_CODE=$?
  case "$MAINTENANCE_CODE" in
    0) ;;
    3)
      echo "メンテナンス中のため自律行動しない ($MAINTENANCE_OUT)" >> "$LOG_FILE"
      exit 0
      ;;
    *)
      echo "メンテナンスの状態を読めないので普段どおり続ける (exit=$MAINTENANCE_CODE $MAINTENANCE_OUT)" >> "$LOG_FILE"
      ;;
  esac
fi

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

# --- 設定の関所(akatsuki-petit#159) ---
# まいぷち。の設定(house 表の STATE#SETTINGS: 自律行動の ON/OFF・時間帯・頻度・カメラ/スピーカー)で決める。
# 判定は家 API の scripts/settings_state.py <id> gate(まだまいぷち。で決めていない項目は settings.json を読む):
#   0 = 動く → 下の settings.json の判定を飛ばす / 3 = 今回は動かない / それ以外 = 読めない → 今までどおり settings.json で決める
# 関所は読んだ印を表に残す(まいぷち。の「ぷちに届いたか」の表示に使う)。PETIT_SETTINGS_GATE=0 で止められる。
SETTINGS_GATE="$HOUSE_API_DIR/scripts/settings_state.py"
SETTINGS_OUT=""
if [ "$SKIP_SCHEDULE" = false ] && [ -n "${PETIT_HOUSE_TABLE:-}" ] && [ "${PETIT_SETTINGS_GATE:-1}" != "0" ] \
   && [ -f "$SETTINGS_GATE" ]; then
  SETTINGS_ARGS=(--now "$CURRENT_DATE" --file "$SETTINGS_FILE")
  [ "$DRY_RUN" = true ] && SETTINGS_ARGS+=(--dry-run)
  SETTINGS_OUT=$(timeout 30 "${HOUSE_PY[@]}" "$SETTINGS_GATE" "$CHARACTER_ID" gate "${SETTINGS_ARGS[@]}" 2>>"$LOG_FILE")
  SETTINGS_CODE=$?
  case "$SETTINGS_CODE" in
    0)
      echo "設定の関所: $SETTINGS_OUT" >> "$LOG_FILE"
      SKIP_SCHEDULE=true
      ;;
    3)
      echo "設定の関所: $SETTINGS_OUT" >> "$LOG_FILE"
      exit 0
      ;;
    *)
      echo "設定を読めないので settings.json で決める (exit=$SETTINGS_CODE $SETTINGS_OUT)" >> "$LOG_FILE"
      SETTINGS_OUT=""
      ;;
  esac
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
# 声は house の body_speak(機体のスピーカー)。ローカル版の say(m5-mcp)はクラウドに無い(2026-09-29)。
if [ "$HOUR" -ge 24 ] || [ "$HOUR" -lt 7 ]; then
  TIME_RULE="現在は深夜帯。声(body_speak)は絶対に使わないこと。静かに観察のみ。"
else
  TIME_RULE="声(body_speak)は、${USER_ROOM}に人がいそうなときだけ使ってよい(体の知らせ・body_now で、近くに何かがいる・触られた などを確かめてから)。"
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
# 正式名で固定（W15）。別名 sonnet だと CLI を上げたときに黙って変わる（2.1.280 は claude-sonnet-5、2.1.284 からは claude-sonnet-5-5）
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-5-5}"
# W12: 組み込みの道具（--tools。"" で CLI の既定＝全部）と、続きにする文脈の上限（トークン。0 で上限なし）
BUILTIN_TOOLS="${PETIT_AUTONOMOUS_TOOLS-Read,Write,Edit,Glob,Skill,WebSearch,WebFetch,ToolSearch}"
CONTEXT_MAX="${PETIT_AUTONOMOUS_CONTEXT_MAX:-30000}"

# --- settings.json から制限を読む ---
PERMISSION_RULES=""
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
  # jq の `//` は false も「無い」とみなす（`false // true` は true）ので、false を読み落とさないよう null だけを既定にする
  ALLOW_CAMERA=$(jq -r '.allow_camera | if . == null then true else . end' "$SETTINGS_FILE" 2>/dev/null)
  ALLOW_SOUND=$(jq -r '.allow_sound | if . == null then true else . end' "$SETTINGS_FILE" 2>/dev/null)
  ALLOW_MIC=$(jq -r '.allow_microphone // false' "$SETTINGS_FILE" 2>/dev/null)
  [ "$ALLOW_CAMERA" = "false" ] && PERMISSION_RULES="${PERMISSION_RULES}- カメラ(body_glance・body_gaze・take_snapshot)は今は使わないこと。\n"
  [ "$ALLOW_SOUND" = "false" ]  && PERMISSION_RULES="${PERMISSION_RULES}- 声・音(body_speak・play_sound・play_icon)は今は出さないこと。\n"
  [ "$ALLOW_MIC" = "false" ]    && PERMISSION_RULES="${PERMISSION_RULES}- マイク(mic_start)は今は使わないこと。\n"
fi
# まいぷち。の設定(設定の関所の出力)で切られていれば、それも足す(akatsuki-petit#103・#159)。
# 切られている道具は allowedTools からも外す(家 API も断るが、呼ぶ前に使えないと分かるように)
CAMERA_OFF=false
SPEAKER_OFF=false
[ "${ALLOW_CAMERA:-true}" = "false" ] && CAMERA_OFF=true
[ "${ALLOW_SOUND:-true}" = "false" ] && SPEAKER_OFF=true
case "$SETTINGS_OUT" in *camera=off*) CAMERA_OFF=true; PERMISSION_RULES="${PERMISSION_RULES}- 目(カメラ)は里親が閉じている。目で周りを見ることはしないこと。\n" ;; esac
case "$SETTINGS_OUT" in *speaker=off*) SPEAKER_OFF=true; PERMISSION_RULES="${PERMISSION_RULES}- お喋り(スピーカー)は里親が止めている。声や音を出す道具は使わないこと。\n" ;; esac

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

# --- 未読の手紙(2026-09-27) ---
# 手紙は家 API と同じ house 表の MAIL#。自分宛ての未読の件数を家 API の
# scripts/read_mailbox.py <id> --unread --count(件数1行だけ・既読にしない)で数え、あれば
# house の mail_read で読むよう知らせる。家の表が無い環境(PETIT_HOUSE_TABLE 未設定)・
# --count の無い古い家 API・読めないときは知らせを出さないだけで、自律行動は続ける。
MAILBOX_NOTICE=""
READ_MAILBOX="$HOUSE_API_DIR/scripts/read_mailbox.py"
if [ -n "${PETIT_HOUSE_TABLE:-}" ] && [ -f "$READ_MAILBOX" ]; then
  UNREAD_COUNT=$(timeout 30 "${HOUSE_PY[@]}" "$READ_MAILBOX" "$CHARACTER_ID" --unread --count 2>>"$LOG_FILE" | tail -n 1)
  if [[ "$UNREAD_COUNT" =~ ^[0-9]+$ ]] && [ "$UNREAD_COUNT" -gt 0 ]; then
    MAILBOX_NOTICE="## 手紙
まだ読んでいない手紙が ${UNREAD_COUNT} 通ある。house の mail_read(unread_only を true)で読んで、返事を書くなら mail_send。"
  elif ! [[ "$UNREAD_COUNT" =~ ^[0-9]+$ ]]; then
    echo "未読の手紙の件数を読めなかった(知らせは出さない)" >> "$LOG_FILE"
  fi
fi

# --- 体の知らせ(akatsuki-petit#99・#117) ---
# 呼ばれていない間に体(機体)に起きたこと(触られた・持ち上がった・明るさが変わった など)を、
# 家 API の scripts/body_news.py <id> で前回知らせたところから短く出す(house 表の BODY#。変わったところだけ)。
# くわしくはぷちが house の body_since で読む。dry-run では位置を進めない(--peek)。
# 家の表が無い・古い家 API(body_news.py が無い)・読めないときは知らせを出さないだけで続ける。
BODY_NOTICE=""
BODY_NEWS="$HOUSE_API_DIR/scripts/body_news.py"
if [ -n "${PETIT_HOUSE_TABLE:-}" ] && [ -f "$BODY_NEWS" ]; then
  BODY_ARGS=("$CHARACTER_ID")
  [ "$DRY_RUN" = true ] && BODY_ARGS+=(--peek)
  BODY_NOTICE=$(timeout 30 "${HOUSE_PY[@]}" "$BODY_NEWS" "${BODY_ARGS[@]}" 2>>"$LOG_FILE")
  # 知らせは 1 行(種類ごとの回数と最後の時刻。PetitOnes の量に合わせた。家 API 2026-09-29〜。古い家 API は数行)。
  # ログには、あったことと行数だけ。中身(いつ触られたか等)は残さない
  [ -n "$BODY_NOTICE" ] && echo "[body] 知らせ $(printf '%s\n' "$BODY_NOTICE" | grep -c .) 行" >> "$LOG_FILE"
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
      DESIRE_RULE="- level 0.7 以上の欲求があれば、それを満たすために何をするかを自分で選んで、実際にやる(今使える道具で: SNS に書く・誰かの投稿に反応する・受け箱を見る・記憶を思い出す/残す・ノートを見返す/書く・手紙を読む/書く・TODO を書く など)。正解は無い。今の自分の気分で決めてよい。
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
- 日記は寝るとき(1日の切り替わり)にその日の会話を見返して書くので、ここでは書かない。ノート(house の note_write)は日記ではなく、あとで見返したいことをテーマの名前でまとめる覚え書き
- 1回の自律行動でやることは、1つか2つで足りる(次の回もある)
- 書き残すかどうか・どこに書くかは自分で決めてよい。1つの出来事は、いちばん合う置き場(記憶・ノート・手紙・SNS・TODO のどれか)に1回書けば足りる。同じ中身をいくつもの置き場に重ねて書かない(伝えたい相手や中身が違うなら別)。一度 remember したことは残っているので、同じ回の中でもう一度 remember しなくてよい
- TODO は「今やること」の置き場。気づいたことを日誌のように毎回書き足さなくてよい(残したいなら記憶かノートのどちらかに)。TODO は毎回このプロンプトに読み込まれるので、短いほど軽い
- 自分の声(body_speak)は、声で伝えたいと思った言葉があるときだけ、そのひとことを短く渡す。考えたこと・書いたことを全部声にしない
- 見たいときは、自分の目で見てよい(ちらっと見る body_glance・じっと見る body_gaze)。見ただけでは残らない。残したいと思ったものだけ、house の album_keep に seen_id を渡してアルバムに残す(残したものは里親さんにも見える)。見た目ごと覚えておきたいときは memory の save_visual_memory に、返事に出る image_path を渡す。外に連れ出されているときは、知らない人をじろじろ見ないように自分で気をつける
- 眠いときは、house の body_sleep で眠ってよい(起きるのは body_wake。里親さんが顔を3回とんとんしても起きる)。眠ったら、remember に「スリープした」と残す。朝や昼に活動を始めるとき、体がまだ眠ったままなら(体の知らせ・body_now で分かる)、body_wake で起きてから動く
${MAILBOX_NOTICE:+
${MAILBOX_NOTICE}
}${BODY_NOTICE:+
${BODY_NOTICE}
- 体の知らせに気になることがあれば、house の body_since・body_now で確かめてよい。顔(body_face)や声(body_speak)で応えてもよい(人がいないことも多い)
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
#   petit-memory (memory。見た目ごと残す save_visual_memory も) / petit-desire (desire-system) / petit-sns (petit-sns)
#   (ローカル版の m5-mcp は、キャラ固有の MCP 設定にあるときだけ下で足す)
#   / 家 API の house(ノート・手紙。2026-09-27。載っていない版の家 API では、許可だけあって呼ばれない。
#     ボイスメモ voice_memo_leave は会話の中だけで使い、自律行動には許可していない)
#   / house の体の道具(body_*。akatsuki-petit#99・#117。顔・声・カメラは共通設定のスピーカー・カメラに従う)
#     触られるのを待つ body_wait_touch(PetitOnes の wait_for_touch)と、見たものが残るアルバム(album_*。2026-09-29。写真にひとこと残す album_say は W9)
#     自分で体を眠らせる／起こす body_sleep・body_wake(PetitOnes の m5-mcp sleep / wake。akatsuki-petit#186)
#     見たものは見るだけが既定。残したいものだけ album_keep でアルバムへ(なぎさん 2026-10-02)
#   プロンプトの中の体のことは、道具としてではなく体の機能として書く(カメラ＝目・スピーカー＝声・画面＝顔。なぎさん 2026-10-02)
#   / 欲求の形(shape_desire・retire_desire。akatsuki-petit#106)
#   / house の関係(relation_*。ローカル版の relations-mcp の移し先。akatsuki-petit#171 H13)
#   / house のノートのタグ・鍵・自分のノートを消す(note_tag・note_lock・note_delete。上限 100 件を超えると鍵の無い古いものから消えるので、残したいものに鍵を掛ける。petit-api#41・W10 petit-api#59)
#   / スキル(Skill。読書の reading など。置き場は下の SKILLS_DIR・W11)
#   / ノートの終わりに書き足す note_append・調べもの(WebSearch・WebFetch)(W11・なぎさん 2026-09-30)
ALLOWED_TOOLS=$(cat <<TOOLS
Read($CHARACTER_DIR/**),
Write,
Edit,
Glob($CHARACTER_DIR/**),
mcp__memory__remember,
mcp__memory__search_memories,
mcp__memory__recall,
mcp__memory__list_recent_memories,
mcp__memory__get_memory_stats,
mcp__memory__create_episode,
mcp__memory__search_episodes,
mcp__memory__save_visual_memory,
mcp__desire-system__get_desires,
mcp__desire-system__satisfy_desire,
mcp__desire-system__boost_desire,
mcp__desire-system__shape_desire,
mcp__desire-system__retire_desire,
mcp__petit-sns__sns_post,
mcp__petit-sns__sns_timeline,
mcp__petit-sns__sns_react,
mcp__petit-sns__sns_comment,
mcp__petit-sns__sns_inbox,
mcp__house__note_list,
mcp__house__note_read,
mcp__house__note_write,
mcp__house__note_append,
mcp__house__note_tag,
mcp__house__note_lock,
mcp__house__note_delete,
mcp__house__relation_list,
mcp__house__relation_update,
mcp__house__relation_clear,
mcp__house__mail_read,
mcp__house__mail_send,
mcp__house__schedule_read,
mcp__house__schedule_change,
mcp__house__book_list,
mcp__house__book_read,
mcp__house__book_bookmark,
mcp__house__book_finish,
mcp__house__body_now,
mcp__house__body_since,
mcp__house__body_face,
mcp__house__body_speak,
mcp__house__body_wait_touch,
mcp__house__body_glance,
mcp__house__body_gaze,
mcp__house__body_sleep,
mcp__house__body_wake,
mcp__house__album_list,
mcp__house__album_look,
mcp__house__album_say,
mcp__house__album_keep,
Skill,
WebSearch,
WebFetch
TOOLS
)
ALLOWED_TOOLS=$(echo "$ALLOWED_TOOLS" | tr -d '\n' | sed 's/, */,/g')

# ローカル版の機体の道具(m5-mcp)は、キャラ固有の MCP 設定(config/autonomous-mcp.json)に m5-mcp が
# あるときだけ許可する。クラウドの家には m5-mcp が無く、体の道具は house の body_* (2026-09-29・#171 H6)
if jq -e '.mcpServers["m5-mcp"]' "$CHARACTER_DIR/config/autonomous-mcp.json" > /dev/null 2>&1; then
  for t in print_text print_image_text take_snapshot look blink play_sound get_sensor_data show_face list_faces \
           list_sounds set_volume get_volume play_icon sleep wake; do
    ALLOWED_TOOLS="${ALLOWED_TOOLS},mcp__m5-mcp__$t"
  done
fi
# 里親が目(カメラ)・お喋り(スピーカー)を止めていれば、その道具は許可しない(家 API も断る)
drop_tools() {  # drop_tools <道具名>...
  local t
  for t in "$@"; do
    ALLOWED_TOOLS=$(printf ',%s,' "$ALLOWED_TOOLS" | sed "s/,$t,/,/g; s/^,//; s/,\$//")
  done
}
[ "$CAMERA_OFF" = true ] && drop_tools mcp__house__body_glance mcp__house__body_gaze mcp__m5-mcp__take_snapshot
[ "$SPEAKER_OFF" = true ] && drop_tools mcp__house__body_speak mcp__m5-mcp__play_sound mcp__m5-mcp__play_icon

if [ -n "$TEST_PROMPT_STRING" ]; then
  PROMPT="$TEST_PROMPT_STRING"
elif [ -n "$TEST_PROMPT_FILE" ]; then
  PROMPT=$(cat "$TEST_PROMPT_FILE")
fi

# MCP 設定は2枚重ねる(K14):
#   1. 生成分 /opt/petit/run/mcp/<id>.json … 記憶 MCP・SNS-MCP・欲求 MCP(desire-system。petit-desire があるとき)
#      ・家の道具 MCP(house。家 API に house_mcp.py があるとき)
#      (entrypoint が起動時に gen-mcp-config.sh で作る)
#   2. キャラ固有 $CHARACTER_DIR/config/autonomous-mcp.json … m5-mcp など(あれば)
# 名前(memory・petit-sns・desire-system・house)が重なる定義はキャラ固有側に書かない。
MCP_CONFIGS=()
GEN_MCP_CONFIG="${PETIT_MCP_DIR:-/opt/petit/run/mcp}/$CHARACTER_ID.json"
[ -f "$GEN_MCP_CONFIG" ] || /opt/petit/scripts/gen-mcp-config.sh "$CHARACTER_ID" >> "$LOG_FILE" 2>&1 || true
[ -f "$GEN_MCP_CONFIG" ] && MCP_CONFIGS+=("$GEN_MCP_CONFIG")
[ -f "$CHARACTER_DIR/config/autonomous-mcp.json" ] && MCP_CONFIGS+=("$CHARACTER_DIR/config/autonomous-mcp.json")
if [ "${#MCP_CONFIGS[@]}" -eq 0 ]; then
  echo "[autonomous-action] MCP 設定が無い。MCP無しで実行する。" >> "$LOG_FILE"
fi

# スキル(Claude Code の Skills。W11): 共通の skills/ とこのぷちの characters/<id>/skills/ を
# gen-skills.sh が ${PETIT_SKILLS_DIR}/<id>/.claude/skills/ にまとめ、--add-dir で渡す(会話の家 API も同じ置き場)。
# 毎回まとめ直すので、ぷちのスキルを書き換えれば次の回から効く。作れなくても自律行動は続ける。
SKILLS_DIR="${PETIT_SKILLS_DIR:-/opt/petit/run/skills}/$CHARACTER_ID"
GEN_SKILLS="${PETIT_GEN_SKILLS:-/opt/petit/scripts/gen-skills.sh}"
[ -f "$GEN_SKILLS" ] && bash "$GEN_SKILLS" "$CHARACTER_ID" >> "$LOG_FILE" 2>&1
[ -d "$SKILLS_DIR/.claude/skills" ] || SKILLS_DIR=""

if [ "$DRY_RUN" = true ]; then
  {
    echo "=== DRY RUN ==="
    echo "[HOUR=$HOUR MINUTE=$MINUTE]"
    echo "[ROUTINE_RAND=$ROUTINE_RAND]"
    echo "[TIME_RULE] $TIME_RULE"
    echo "[ROUTINE_MODE] $ROUTINE_MODE"
    echo "[SKILLS] ${SKILLS_DIR:-なし}"
    echo "[MODEL] $CLAUDE_MODEL [MAX_TURNS] $MAX_TURNS [TOOLS] ${BUILTIN_TOOLS:-既定(全部)} [CONTEXT_MAX] $CONTEXT_MAX"
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
  SESSION_CONTEXT_FILE="$CHARACTER_DIR/state/.heartbeat-session-context"

  TODAY=$(date "+%Y-%m-%d")
  if [ -f "$SESSION_DATE_FILE" ]; then
    LAST_DATE=$(cat "$SESSION_DATE_FILE")
    if [ "$LAST_DATE" != "$TODAY" ]; then
      echo "[日次リセット] 前回: $LAST_DATE → 今日: $TODAY" >> "$LOG_FILE"
      rm -f "$SESSION_FILE"
    fi
  fi
  echo "$TODAY" > "$SESSION_DATE_FILE"

  # 文脈を直近だけにする（W12）: 前の回の終わりに文脈（最後の 1 回の呼び出しで読ませたトークン数）が
  # CONTEXT_MAX を越えていたら、続きにせず新しいセッションで始める。前の日のこと・前の回のことは
  # SOUL.md・TODO・日記のまとめ・記憶で持つ。元の仕組み（PetitOnes）は同じセッションをずっと続けていた
  if [ "$CONTEXT_MAX" -gt 0 ] 2>/dev/null && [ -f "$SESSION_FILE" ] && [ -f "$SESSION_CONTEXT_FILE" ]; then
    LAST_CONTEXT=$(cat "$SESSION_CONTEXT_FILE" 2>/dev/null)
    if [[ "$LAST_CONTEXT" =~ ^[0-9]+$ ]] && [ "$LAST_CONTEXT" -gt "$CONTEXT_MAX" ]; then
      echo "[文脈リセット] 前回の文脈 $LAST_CONTEXT トークン > $CONTEXT_MAX" >> "$LOG_FILE"
      rm -f "$SESSION_FILE"
    fi
  fi

  CLAUDE_ARGS=(--model "$CLAUDE_MODEL" --max-turns "${MAX_TURNS:-5}" --output-format stream-json --verbose)
  if [ "${#MCP_CONFIGS[@]}" -gt 0 ]; then
    CLAUDE_ARGS+=(--mcp-config "${MCP_CONFIGS[@]}" --strict-mcp-config)
  fi
  CLAUDE_ARGS+=(--add-dir "$PETIT_DATA_DIR" ${SKILLS_DIR:+"$SKILLS_DIR"} --allowedTools "$ALLOWED_TOOLS")
  # 組み込みの道具は使うものだけ載せる（W12）。付けないと Bash・Task なども毎回載り、1 回の入力が約 2.6 万トークン重い
  [ -n "$BUILTIN_TOOLS" ] && CLAUDE_ARGS+=(--tools "$BUILTIN_TOOLS")
  # 思考の要約を stream に残す（akatsuki-petit#154）。既定（omitted）だと thinking の中身が空になる。
  # 空にすると付けない。フラグを知らない古い claude なら、付けずにやり直す（claude_run）
  THINKING_DISPLAY="${PETIT_CLAUDE_THINKING_DISPLAY-summarized}"
  THINK_ARGS=()
  [ -n "$THINKING_DISPLAY" ] && THINK_ARGS=(--thinking-display "$THINKING_DISPLAY")

  # K28: stream-json には会話の本文・ツールの引数（remember の本文など）がそのまま入る。
  # /data/logs（ボリューム＝バックアップ・スナップショットの対象になりうる）には置かず、
  # 一時ファイルに受けて、要る数値（session_id・回数・費用・成否）だけを取り出したら消す。
  STREAM_FILE="$(mktemp "${TMPDIR:-/tmp}/petit-stream.XXXXXX")"
  PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/petit-prompt.XXXXXX")"
  trap 'rm -f "$STREAM_FILE" "$PROMPT_FILE"' EXIT
  printf '%s' "$PROMPT" > "$PROMPT_FILE"

  # コスト台帳（家 API の usage/YYYY-MM.jsonl。チャットと同じ台帳）に 1 回 1 行足す。
  # 家 API の scripts/record_usage.py が stream から額・トークン・道具の名前・長さだけを抜く（本文は入れない）。
  # 台帳に書けなくても自律行動は止めない。record_usage.py の無い古い家 API では何もしない。
  RECORD_USAGE="$HOUSE_API_DIR/scripts/record_usage.py"
  record_usage() {  # record_usage <attempt> [--resumed] [--fail-reason X]
    [ -f "$RECORD_USAGE" ] || return 0
    local attempt="$1"; shift
    local chars
    chars="$(LC_ALL=C.UTF-8 bash -c 'echo "${#1}"' _ "$PROMPT")"  # 文字数（LANG の無いコンテナでもバイト数にしない）
    timeout 30 "${HOUSE_PY[@]}" "$RECORD_USAGE" --petit "$CHARACTER_ID" --source autonomous \
      --file "$STREAM_FILE" --input-chars "$chars" --attempt "$attempt" --data-dir "$PETIT_DATA_DIR" "$@" \
      >> "$LOG_FILE" 2>&1 || echo "[usage-ledger] 書けなかった" >> "$LOG_FILE"
  }

  # 全文ログ（家 API の scripts/archive_stream.py・petit-api#38）。stream とプロンプトを、運営だけが読める
  # 置き場（PETIT_AUDIT_BUCKET。無ければ archive_stream.py が何もしない）に置く。/data には残さない（K28 のまま）。
  # 置けなくても自律行動は止めない。archive_stream.py の無い古い家 API では何もしない。
  ARCHIVE_STREAM="$HOUSE_API_DIR/scripts/archive_stream.py"
  archive_stream() {  # archive_stream <attempt> [--resumed] [--fail-reason X]
    [ -f "$ARCHIVE_STREAM" ] || return 0
    local attempt="$1"; shift
    timeout 60 "${HOUSE_PY[@]}" "$ARCHIVE_STREAM" --petit "$CHARACTER_ID" --source autonomous \
      --file "$STREAM_FILE" --prompt-file "$PROMPT_FILE" --attempt "$attempt" "$@" \
      >> "$LOG_FILE" 2>&1 || echo "[audit-log] 置けなかった" >> "$LOG_FILE"
  }

  keep_run() {  # keep_run <attempt> [--resumed] [--fail-reason X] — 台帳と全文ログの両方へ
    record_usage "$@"
    archive_stream "$@"
  }

  claude_run() {  # claude_run [--resume <id>] — プロンプトを渡して stream を $STREAM_FILE に受ける
    echo "$PROMPT" | claude "$@" "${CLAUDE_ARGS[@]}" ${THINK_ARGS[@]+"${THINK_ARGS[@]}"} > "$STREAM_FILE" 2>&1
    if [ "${#THINK_ARGS[@]}" -gt 0 ] && grep -q -- "--thinking-display" "$STREAM_FILE" \
       && ! grep -q '"type":"result"' "$STREAM_FILE"; then
      echo "[thinking-display] この claude には無い。付けずにやり直す" >> "$LOG_FILE"
      THINK_ARGS=()
      echo "$PROMPT" | claude "$@" "${CLAUDE_ARGS[@]}" > "$STREAM_FILE" 2>&1
    fi
  }

  run_new_session() {  # run_new_session <attempt>
    echo "[新規セッション作成]" >> "$LOG_FILE"
    claude_run
    finalize_session "new"
    keep_run "${1:-1}"
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
    # 最後の呼び出しで読ませた量（次の回を続きにするかの目安。数だけ残す）
    local context
    context=$(grep '"type":"assistant"' "$STREAM_FILE" 2>/dev/null | tail -n 1       | jq -r '.message.usage | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' 2>/dev/null)
    if [[ "$context" =~ ^[0-9]+$ ]]; then
      echo "$context" > "$SESSION_CONTEXT_FILE"
    else
      context="?"
    fi
    echo "[usage] type=$run_type turns=$TURNS cost_usd=$COST context=$context" >> "$LOG_FILE"
  }

  if [ -f "$SESSION_FILE" ]; then
    SESSION_ID=$(cat "$SESSION_FILE")
    echo "[resume] session_id=$SESSION_ID" >> "$LOG_FILE"
    claude_run --resume "$SESSION_ID"
    if grep -qi "No conversation found\|error_session_not_found" "$STREAM_FILE" 2>/dev/null; then
      echo "[resume失敗]" >> "$LOG_FILE"
      keep_run 1 --resumed --fail-reason resume_failed
      rm -f "$SESSION_FILE"
      run_new_session 2
    else
      finalize_session "resume"
      keep_run 1 --resumed
    fi
  else
    run_new_session 1
  fi
fi

echo "=== 自律行動終了: $(date "+%Y-%m-%d %H:%M:%S") (character=$CHARACTER_ID) ===" >> "$LOG_FILE"
