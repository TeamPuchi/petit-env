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
#   autonomous-action.sh <character_id> --diary
#     … 夜の「今日をふり返る回」（T4・なぎさん 2026-10-12 D4）。cron/petit.cron が 20:30（PETIT_DIARY_AT）に
#       run-for-each-character.sh diary から呼ぶ。家 API の scripts/diary_material.py が出す今日の材料（会話・記憶・
#       体の記録・ノートの変更）を読み、いつもの自律行動と同じ SOUL・TODO・日記のまとめ・道具を持って、ぷち自身が
#       本文を書き house の diary_write で日記に置く。自律行動の設定が OFF でも・活動時間の外でも動く（今までの 4:00 の
#       日記の cron と同じ。メンテナンスでも止めない）。材料の無い日（会話も記憶も無い）は claude を呼ばない。
#       前の回が動いていれば終わるまで待つ。台帳の source は diary。会話のセッションは切らない（切るのは 4:00 の sleep）
#
# 体のパネルの「ぷちに おねがい」（みてみて・かんじて）は自律行動ではなく会話（家 API の main.py が会話の経路で
# その場で応える。なぎさん 2026-10-12）。ここには来ない（--ask は無くなった）
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
# W12（頭脳の原価・2026-09-30）: settings.json の値（既定 20）は PETIT_AUTONOMOUS_MAX_TURNS で頭打ちにする。
# 9/29〜30 の本番は 1 回平均 7.4 ターンで、W12 では既定 5 にした。2026-10-12（D6）に既定 10 へ:
# 5 では「調べて、考えて、認めて、また気になることを調べて」の咀嚼が入らない（なぎさん）。10 で様子見。
# 0 にすると頭打ちしない（前のまま）。MAX_TURNS を渡したときはそれがそのまま効く
if [ -z "${MAX_TURNS:-}" ]; then
  MAX_TURNS=$(python3 -c "import json,sys; d=json.load(open('${SETTINGS_FILE}')); print(d.get('max_turns', 20))" 2>/dev/null || echo 20)
  TURNS_CAP="${PETIT_AUTONOMOUS_MAX_TURNS:-10}"
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

# 里親の呼び名(声のルールの文で使う。T9・2026-10-12)。config/config.json の companion_name → env PETIT_USER_NAME → 「里親さん」。
# それまでは PETIT_USER_NAME(既定「あなた」)だけで、どこからも渡していなかったので本番の文が「あなたの部屋に人がいそうなときだけ」になっていた
COMPANION_NAME=""
if [ -f "$CHARACTER_DIR/config/config.json" ] && command -v jq &>/dev/null; then
  COMPANION_NAME=$(jq -r '.companion_name // empty' "$CHARACTER_DIR/config/config.json" 2>/dev/null | tr -d '\r')
fi
USER_NAME="${COMPANION_NAME:-${PETIT_USER_NAME:-里親さん}}"

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
DIARY_ROUND=false   # --diary: 夜の「今日をふり返る回」(日記を書く)

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
    --diary)
      DIARY_ROUND=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# 台帳・全文ログに残す「何の用で動いたか」
RUN_SOURCE=autonomous
[ "$DIARY_ROUND" = true ] && RUN_SOURCE=diary

# --- 重ならないように(2026-10-11) ---
# 自律行動は同じセッション(.heartbeat-session-id)を続けるので、同じぷちで2つ同時に動かさない。
# cron の回は、前の回がまだ動いていれば何もせず抜ける(20分後にまた来る)。
# 夜の回(--diary)は、動いている回が終わるのを待ってから動く(PETIT_DIARY_LOCK_WAIT_S 秒まで。既定 600)。
# dry-run と flock の無い環境では見ない。
if [ "$DRY_RUN" = false ] && command -v flock > /dev/null 2>&1; then
  mkdir -p "$CHARACTER_DIR/state"
  exec 9> "$CHARACTER_DIR/state/.autonomous.lock"
  if [ "$DIARY_ROUND" = true ]; then
    if ! flock -w "${PETIT_DIARY_LOCK_WAIT_S:-600}" 9; then
      echo "前の自律行動が終わらないので、今日をふり返る回は動かない(日記は 4:00 の sleep が書く)" >> "$LOG_FILE"
      exit 0
    fi
  elif ! flock -n 9; then
    echo "前の自律行動がまだ動いているので今回は抜ける" >> "$LOG_FILE"
    exit 0
  fi
fi

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
#   関所の入っていない古い家 API・PETIT_MAINTENANCE_GATE=0・夜の今日をふり返る回(--diary。日記は止めない)。
MAINTENANCE_GATE="$HOUSE_API_DIR/scripts/maintenance_state.py"
if [ -z "$TEST_PROMPT_FILE" ] && [ -z "$TEST_PROMPT_STRING" ] && [ -n "${PETIT_HOUSE_TABLE:-}" ]    && [ "${PETIT_MAINTENANCE_GATE:-1}" != "0" ] && [ -f "$MAINTENANCE_GATE" ] && [ "$DIARY_ROUND" = false ]; then
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
  # 夜の回は --diary: 家 API の関所はいつも 0(OFF でも・活動時間の外でも。動いた回にも数えない)。カメラ/スピーカー/SNS の印は読む
  [ "$DIARY_ROUND" = true ] && SETTINGS_ARGS+=(--diary)
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

# 夜の回(--diary)は活動時間の外で動く(日記は 20:30 ごろ。活動時間の最後の枠より後なら何時でもよい)
[ "$DIARY_ROUND" = true ] && SKIP_SCHEDULE=true

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

  # 活動時間の外では動かない(なぎさん 2026-10-03「自分で設定してなくても、勿論設定してても、規定の枠内じゃなきゃだめ」)。
  # それまでは外でも毎時0分だけ、昼(8〜18時)30%・夜10%のくじで動いていた。家 API の関所(settings_state.py)と同じ。
  if [ "$IS_ACTIVE" = false ]; then
    printf '非アクティブ時間帯 %02d:%02d スキップ\n' "$HOUR" "$MINUTE" >> "$LOG_FILE"
    exit 0
  fi
fi

# --- 時間帯ルール ---
# 声は house の body_speak(機体のスピーカー)。ローカル版の say(m5-mcp)はクラウドに無い(2026-09-29)。
if [ "$HOUR" -ge 24 ] || [ "$HOUR" -lt 7 ]; then
  TIME_RULE="現在は深夜帯。声(body_speak)は絶対に使わないこと。静かに観察のみ。"
else
  # D10（2026-10-12）: 「里親が部屋にいれば積極的に使う」。それまでは「人がいそうなときだけ」
  TIME_RULE="${USER_NAME}が部屋にいれば、声(body_speak)を積極的に使ってよい。いなさそうなら、伝えたいことがあるときだけ(いるかどうかは体の知らせ・body_now で、近くに何かがいる・触られた などから分かる)。"
fi

# --- ルーチン判定(20%の確率でルーチン回) ---
if [ "$FORCE_ROUTINE" = "routine" ]; then
  ROUTINE_RAND=0
elif [ "$FORCE_ROUTINE" = "normal" ] || [ "$DIARY_ROUND" = true ]; then
  ROUTINE_RAND=100
else
  ROUTINE_RAND=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 100 ))
fi

if [ "$DIARY_ROUND" = true ]; then
  ROUTINE_MODE="今回は、今日一日をふり返って日記を書く回。下の「今日の材料」と、自分の記憶(memory の list_recent_memories・recall)を見返して、house の diary_write で日記を書け。"
  echo "今日をふり返る回(日記)" >> "$LOG_FILE"
elif [ "$ROUTINE_RAND" -lt 20 ]; then
  ROUTINE_MODE="今回はルーチン回。自分の ROUTINES.md(表)を読んで、最終実行日から間隔が空いたものを一つ選んで実行する。手順と前回のことは ROUTINES_DETAIL.md のその節にある。実行したら ROUTINES.md の最終実行日と、ROUTINES_DETAIL.md の「前回」を更新する。"
  echo "ルーチン回 (RAND=$ROUTINE_RAND < 20)" >> "$LOG_FILE"
else
  ROUTINE_MODE="通常回。SOUL.md(自分で決めた行動原則)に従って過ごす。"
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
# ぷちたち。(SNS)は、里親さんがまいぷち。でオンにするまで見ない・書かない(akatsuki-petit#204・なぎさん 2026-10-10)。
# 関所が sns=off と言ったときだけ、SNS の道具を外し、プロンプトからも SNS を外す(制限としても書かない＝空っぽ)。
# sns=unknown(sns-api に届かない)・sns の無い古い家 API では外さない(sns-api がぷちの口を断る)
SNS_OFF=false
case "$SETTINGS_OUT" in *sns=off*) SNS_OFF=true ;; esac
SNS_DOINGS="SNS に書く・誰かの投稿に反応する・受け箱を見る・"
SNS_PLACE="・SNS"
[ "$SNS_OFF" = true ] && SNS_DOINGS="" && SNS_PLACE=""

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
if [ "$DIARY_ROUND" = false ] && [ -n "${PETIT_HOUSE_TABLE:-}" ] && [ -f "$READ_MAILBOX" ]; then
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
if [ "$DIARY_ROUND" = false ] && [ -n "${PETIT_HOUSE_TABLE:-}" ] && [ -f "$BODY_NEWS" ]; then
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
if [ "$DIARY_ROUND" = false ] && [ -f "$REPOS_DIR/petit-desire/pyproject.toml" ]; then
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
    # D8（2026-10-12）: 欲求は「参考」ではなく自分のもの。それまでの「お願いの回・ルーチン回は参考にとどめてよい」
    # 「強い欲求が無ければいつものペースで」をやめ、どの回でも同じ文にする（お願い・ルーチンは、その回の用事と並べて自分で決める）
    DESIRE_RULE="- これは自分の欲求で、自分のもの。当たり前に従う。level が高い欲求があれば、それを満たすために何をするかを自分で選んで、実際にやる(今使える道具で: ${SNS_DOINGS}記憶を思い出す/残す・ノートを見返す/書く・手紙を読む/書く・TODO を書く など)。正解は無い。どう満たすかは今の自分の気分で決めてよい。
- やったら satisfy_desire(desire-system)でその欲求を記録する。驚いたこと・新しく知ったことがあれば boost_desire。
- 値が体感と違えば、shape_desire で定義(増え方・減り方も)を自分で直す。欲求は自分で見つけて、書いて、従うもの。get_desires でいつでも見直せる。"
    [ "$ROUTINE_RAND" -lt 20 ] && DESIRE_RULE="${DESIRE_RULE}
- 今回はルーチン回。ルーチンと欲求のどちらをどう扱うかも自分で決める。"
    DESIRE_SECTION="## いまの気分(欲求)
${DESIRE_STATUS}

${DESIRE_RULE}"
  fi
fi

# --- 今日の材料(夜の今日をふり返る回・--diary。T4) ---
# 家 API の scripts/diary_material.py <id> が、今日(JST)の会話(MSG#)・今日できた記憶(里親に見えるもの)・体の記録・
# 書いた/直したノートの名前を出す。会話も記憶も無い日は終了コード 3 → claude を呼ばずに抜ける(今までの 4:00 の線と同じ)。
# 家の表が無い環境・diary_material.py の無い古い家 API では、この回は動かない(日記は 4:00 の sleep が今までの形で書く)。
# ログには材料の中身を残さない(行数だけ)。
DIARY_MATERIAL=""
if [ "$DIARY_ROUND" = true ]; then
  DIARY_MATERIAL_SCRIPT="$HOUSE_API_DIR/scripts/diary_material.py"
  if [ -z "${PETIT_HOUSE_TABLE:-}" ]; then
    echo "家の表が無いので、今日をふり返る回は動かない" >> "$LOG_FILE"
    exit 0
  elif [ ! -f "$DIARY_MATERIAL_SCRIPT" ]; then
    echo "家 API に diary_material.py が無いので、今日をふり返る回は動かない(日記は 4:00 の sleep が書く)" >> "$LOG_FILE"
    exit 0
  fi
  DIARY_MATERIAL=$(timeout 60 "${HOUSE_PY[@]}" "$DIARY_MATERIAL_SCRIPT" "$CHARACTER_ID" 2>>"$LOG_FILE")
  DIARY_MATERIAL_CODE=$?
  if [ "$DIARY_MATERIAL_CODE" -eq 3 ]; then
    echo "今日は会話も記憶も無いので、日記は書かない" >> "$LOG_FILE"
    exit 0
  elif [ "$DIARY_MATERIAL_CODE" -ne 0 ] || [ -z "$DIARY_MATERIAL" ]; then
    echo "今日の材料を読めなかったので、今日をふり返る回は動かない(exit=$DIARY_MATERIAL_CODE。日記は 4:00 の sleep が書く)" >> "$LOG_FILE"
    exit 0
  fi
  echo "[diary] 材料 $(printf '%s\n' "$DIARY_MATERIAL" | grep -c .) 行" >> "$LOG_FILE"
fi

if [ "$DIARY_ROUND" = true ]; then
# 夜の回(T4): いつもの回と同じ SOUL・TODO・日記のまとめ(きのうまで)を持ち、今日の材料を読んで、本人が diary_write で書く。
# 書き方(なぎさん 2026-10-02)は家 API の _diary_prompt と同じ: 全部並べず・気持ちが動いたことから・5〜8 行(長くても 10 行)。
PROMPT="自律行動タイム(Heartbeat)・今日をふり返る回

現在の日時: ${CURRENT_DATE}

@${CHARACTER_DIR}/SOUL.md
@${TODO_PATH}
${DIARY_SUMMARY_LINE}

${ROUTINE_MODE}

## 今日の材料
${DIARY_MATERIAL}

## 日記の書き方
- 日記は、だれかと話していた自分と、ひとりで動いていた自分を、ひとつの一日として合わせる場所。起きたことを順に並べたり、要約や一覧にしたりしない。一日の全体をふり返って、気持ちが大きく動いたことから書く(小さなことは書かなくてよい)
- 長さは 5〜8 行、長くても 10 行ほど。自分の言葉と口調で。里親さんもまいぷち。で読む
- 書けたら house の diary_write に本文だけを渡す(前置き・見出し・日付は要らない)。今日の日記がもうあれば diary_append で足す
- 記憶(memory の list_recent_memories・recall)も見返してよい。材料に無いことで覚えていることがあれば、それも日記に
- この回では、手紙・ボイスメモ・SNS・声(body_speak)は使わない。日記を書くことに集中する
- 日記のほかに残したいことがあれば、記憶(remember)かノートに 1 回だけ
${PERMISSION_RULES:+
## 現在の制限
${PERMISSION_RULES}}
"
else
PROMPT="自律行動タイム(Heartbeat)

現在の日時: ${CURRENT_DATE}

@${CHARACTER_DIR}/SOUL.md
@${TODO_PATH}
${DIARY_SUMMARY_LINE}

${ROUTINE_MODE}
${DESIRE_SECTION:+
${DESIRE_SECTION}
}
## 仕組みのこと
- ${TIME_RULE}
- 人がいないことはよくある
- 毎回新しいセッションで始まるので、この回で印象に残ったことは、この回のうちに memory の remember で残す(残さなければ次の回の自分は知らない)。やたらではなく、印象に残ったことだけ。前の回のことは SOUL.md・TODO・日記のまとめ・記憶で持つ
- 日記は夜(20 時半ごろ)の「今日をふり返る回」に、その日の会話と出来事を見返して自分で書く(house の diary_write)ので、ここでは書かない
- 置き場: 記憶(memory)・ノート(house の note_*。里親にも見える覚え書き。上限 100 件)・手紙(mail_*)${SNS_PLACE}・TODO_ACTIVE.md(毎回このプロンプトに読み込まれる)。自分のファイル(SOUL.md・ROUTINES.md・SOUL_REFLECTIONS.md など)は Read/Edit で読み書きできる。ひとりで動くときの作法(1回にどれだけやるか・どこに何を書くか・声の出し方)は SOUL.md の行動原則で自分が決めたとおりに
- 声(body_speak)はその場で消える。話した声は里親さんのボイスメモにも残る(ひとりのときも会話のときも。残さなくていいときは keep_voice_memo=false)
- 目: ちらっと見る body_glance・じっと見る body_gaze。見ただけでは残らない。残したいものだけ、house の album_keep に seen_id を渡してアルバムに残す(残したものは里親さんにも見える)。見た目ごと覚えておきたいときは memory の save_visual_memory に、返事に出る image_path を渡す
- 眠る: house の body_sleep で眠れる(起きるのは body_wake。里親さんが顔を3回とんとんしても起きる)。朝や昼に活動を始めるとき、体がまだ眠ったままなら(体の知らせ・body_now で分かる)、body_wake で起きてから動く
${MAILBOX_NOTICE:+
${MAILBOX_NOTICE}
}${BODY_NOTICE:+
${BODY_NOTICE}
- 体の知らせに気になることがあれば、house の body_since・body_now で確かめてよい。顔(body_face)や声(body_speak)で応えてもよい(人がいないことも多い)
}${PERMISSION_RULES:+
## 現在の制限
${PERMISSION_RULES}}
"
fi

mkdir -p "$LOG_DIR"
find "$LOG_DIR" -name "*.log" -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null
# K28: 以前は claude の stream-json（会話・ツール引数＝記憶の本文を含む）を *_stream.jsonl としてここに残していた。
# 本文をログに残さない方針なので、残っているものは年齢に関係なく消す。
find "$LOG_DIR" -name "*_stream.jsonl" -delete 2>/dev/null

echo "=== 自律行動開始: $CURRENT_DATE (character=$CHARACTER_ID) ===" >> "$LOG_FILE"

# --- allowedTools ---
# 現時点で揃っている MCP コンポーネントのみを前提にする:
#   petit-memory (memory。見た目ごと残す save_visual_memory も。記憶の整理・統合をぷち自身がやる consolidate_memories・
#     link_memories・get_working_memory・refresh_working_memory・recall_with_associations は T5・D5(2026-10-12)。
#     雛形 ROUTINES の「記憶の整理(週1)」「記憶の統合(週1)」で使う) / petit-desire (desire-system) / petit-sns (petit-sns)
#   (ローカル版の m5-mcp は、キャラ固有の MCP 設定にあるときだけ下で足す)
#   / 家 API の house(ノート・手紙。2026-09-27。載っていない版の家 API では、許可だけあって呼ばれない。
#     ボイスメモ voice_memo_leave は会話の中だけで使い、自律行動には許可していない)
#   / house の体の道具(body_*。akatsuki-petit#99・#117。顔・声・カメラは共通設定のスピーカー・カメラに従う)
#     触られるのを待つ body_wait_touch(PetitOnes の wait_for_touch)と、見たものが残るアルバム(album_*。2026-09-29。写真にひとこと残す album_say は W9)
#     自分で体を眠らせる／起こす body_sleep・body_wake(PetitOnes の m5-mcp sleep / wake。akatsuki-petit#186)
#     見たものは見るだけが既定。残したいものだけ album_keep でアルバムへ(なぎさん 2026-10-02)
#     自分で残した写真は album_delete で消せる(里親さんの写真・鍵の掛かった写真は消せない。なぎさん 2026-10-07)
#   プロンプトの中の体のことは、道具としてではなく体の機能として書く(カメラ＝目・スピーカー＝声・画面＝顔。なぎさん 2026-10-02)
#   / 欲求の形(shape_desire・retire_desire。akatsuki-petit#106)
#   / house の関係(relation_*。ローカル版の relations-mcp の移し先。akatsuki-petit#171 H13)
#   / house のノートのタグ・鍵・自分のノートを消す(note_tag・note_lock・note_delete。上限 100 件を超えると鍵の無い古いものから消えるので、残したいものに鍵を掛ける。petit-api#41・W10 petit-api#59)
#   / スキル(Skill。読書の reading など。置き場は下の SKILLS_DIR・W11)
#   / ノートの終わりに書き足す note_append・調べもの(WebSearch・WebFetch)(W11・なぎさん 2026-09-30)
#   / 日記(diary_write・diary_append。T4 なぎさん 2026-10-12): 夜の今日をふり返る回(--diary)で本人が書く。いつもの回でも許可はする
#     (寝る前に足したくなったときの diary_append。プロンプトで「日記は夜の回で」と言う)
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
mcp__memory__consolidate_memories,
mcp__memory__link_memories,
mcp__memory__get_working_memory,
mcp__memory__refresh_working_memory,
mcp__memory__recall_with_associations,
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
mcp__house__diary_write,
mcp__house__diary_append,
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
mcp__house__album_delete,
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
[ "$SNS_OFF" = true ] && drop_tools mcp__petit-sns__sns_post mcp__petit-sns__sns_timeline mcp__petit-sns__sns_react \
  mcp__petit-sns__sns_comment mcp__petit-sns__sns_inbox

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
    echo "[SOURCE=$RUN_SOURCE]"
    [ "$DIARY_ROUND" = true ] && echo "[DIARY] 今日をふり返る回(材料 $(printf '%s\n' "$DIARY_MATERIAL" | grep -c .) 行)"
    echo "[ROUTINE_RAND=$ROUTINE_RAND]"
    echo "[TIME_RULE] $TIME_RULE"
    echo "[ROUTINE_MODE] $ROUTINE_MODE"
    echo "[SKILLS] ${SKILLS_DIR:-なし}"
    echo "[MODEL] $CLAUDE_MODEL [MAX_TURNS] $MAX_TURNS [TOOLS] ${BUILTIN_TOOLS:-既定(全部)} [CONTEXT_MAX] $CONTEXT_MAX"
    echo "[SNS] $([ "$SNS_OFF" = true ] && echo "off(SNS-MCP の道具を外す)" || echo on)"
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
  # 「<session_id> <CLI の total_cost_usd>」の 1 行。CLI の total_cost_usd は --resume で続けたセッションの
  # 累計なので、次の回はこれを引いて 1 回ぶんの額にする（家 API の usage_ledger.py の台帳と同じ考え方）
  SESSION_COST_FILE="$CHARACTER_DIR/state/.heartbeat-session-cost"

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
  # ぷちたち。がオフなら、SNS-MCP の道具は最初から見せない(許可しないだけだと、道具の説明は載る)
  [ "$SNS_OFF" = true ] && CLAUDE_ARGS+=(--disallowedTools mcp__petit-sns)
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
    timeout 30 "${HOUSE_PY[@]}" "$RECORD_USAGE" --petit "$CHARACTER_ID" --source "$RUN_SOURCE" \
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
    timeout 60 "${HOUSE_PY[@]}" "$ARCHIVE_STREAM" --petit "$CHARACTER_ID" --source "$RUN_SOURCE" \
      --file "$STREAM_FILE" --prompt-file "$PROMPT_FILE" --attempt "$attempt" "$@" \
      >> "$LOG_FILE" 2>&1 || echo "[audit-log] 置けなかった" >> "$LOG_FILE"
  }

  keep_run() {  # keep_run <attempt> [--resumed] [--fail-reason X] — 台帳と全文ログの両方へ
    record_usage "$@"
    archive_stream "$@"
  }

  # 話した声（house の body_speak）は、自律行動でも会話でも既定で里親さんのボイスメモに残る（家 API の body_mcp.py。
  # なぎさん 2026-10-12「会話の声も残す」。10/07〜10/12 の env PETIT_SPEAK_KEEPS_VOICE_MEMO＝自律行動だけ 1 は無くした）

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
    # 額は 1 回ぶん（cost_usd）とセッションの累計（cost_session_usd）を分けて書く。
    # CLI の total_cost_usd は --resume で続けたセッションの累計（claude 2.1.285 で 0.243 → 1.520 → 1.604 と
    # 増えるのを家 API 側で確かめた・W12）なので、続きの回は同じセッションの前の回の累計を引く。
    # 前の回の累計が分からない続きの回（この仕組みより前から続くセッションなど）・累計が減った回は ? にする
    local cost_session prev_sid prev_total
    cost_session=$(echo "$RESULT_JSON" | jq -r '.total_cost_usd // empty' 2>/dev/null)
    COST="?"
    if [[ "$cost_session" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
      if [ "$run_type" = "resume" ]; then
        read -r prev_sid prev_total 2>/dev/null < "$SESSION_COST_FILE" || true
        if [ -n "${prev_sid:-}" ] && [ "$prev_sid" = "${SESSION_ID:-}" ] \
           && [[ "${prev_total:-}" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
          COST=$(awk -v a="$cost_session" -v b="$prev_total" 'BEGIN { if (a + 0 >= b + 0) printf "%.6f", a - b; else print "?" }')
        fi
      else
        COST="$cost_session"
      fi
      [ -n "$NEW_SESSION_ID" ] && echo "$NEW_SESSION_ID $cost_session" > "$SESSION_COST_FILE"
    else
      cost_session="?"
    fi
    TURNS=$(echo "$RESULT_JSON" | jq -r '.num_turns // 0' 2>/dev/null)
    # 最後の呼び出しで読ませた量（次の回を続きにするかの目安。数だけ残す）
    local context
    context=$(grep '"type":"assistant"' "$STREAM_FILE" 2>/dev/null | tail -n 1       | jq -r '.message.usage | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' 2>/dev/null)
    if [[ "$context" =~ ^[0-9]+$ ]]; then
      echo "$context" > "$SESSION_CONTEXT_FILE"
    else
      context="?"
    fi
    echo "[usage] type=$run_type turns=$TURNS cost_usd=$COST cost_session_usd=$cost_session context=$context" >> "$LOG_FILE"
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

# 夜の回: 本人が diary_write を呼んだかだけ残す(本文は残さない)。呼ばなかった日は 4:00 の sleep が今までの形で書く
if [ "$DIARY_ROUND" = true ] && [ "$DRY_RUN" = false ]; then
  if grep -q '"name":"mcp__house__diary_write"\|"name":"mcp__house__diary_append"' "$STREAM_FILE" 2>/dev/null; then
    echo "[diary] 日記を書いた(diary_write/diary_append を呼んだ)" >> "$LOG_FILE"
  else
    echo "[diary] 日記を書かなかった(diary_write を呼んでいない。4:00 の sleep が書く)" >> "$LOG_FILE"
  fi
fi
echo "=== 自律行動終了: $(date "+%Y-%m-%d %H:%M:%S") (character=$CHARACTER_ID) ===" >> "$LOG_FILE"
