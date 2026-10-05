# petit-env

## [English Page](./README_en.md)

M5 Petit(ぷち)をDockerで動かすためのumbrella実行環境です。[petit-mcp](https://github.com/TeamPuchi/petit-mcp) / [m5-petit-app](https://github.com/TeamPuchi/m5-petit-app) / [petit-memory](https://github.com/TeamPuchi/petit-memory) / [petit-desire](https://github.com/TeamPuchi/petit-desire) / [petit-scripts](https://github.com/TeamPuchi/petit-scripts) を1つのコンテナに組み合わせ、cron相当の自律行動・ダッシュボード・記憶整理などをまとめて起動します。

> このリポジトリは [PetitOnes/m5-petit-env](https://github.com/PetitOnes/m5-petit-env) の fork です。各コンポーネントも PetitOnes からの fork で、TeamPuchi 側では `m5-` 接頭辞を落とした名前に統一しています(`repos/` 配下のディレクトリ名も同じ)。

> ⚠️ **`m5-petit-app` と [`petit-app`](https://github.com/TeamPuchi/petit-app) は別物です。**
> このコンテナが `:8765` で動かすのは従来の FastAPI である `m5-petit-app` の方。
> `petit-app` はクラウド版の Vite + React SPA で、コンテナではなく S3/CloudFront に載ります
> ([petit-infra](https://github.com/TeamPuchi/petit-infra) の `50-web-hosting`)。
> ここだけ `m5-` 接頭辞を残しているのはそのためです。

> **いまの状態(2026-09-29)**: クラウド版(AKATSUKI)のぷちコンテナ `petit-core` のもとです。EC2(t4g・arm64)のホストで
> [petit-infra](https://github.com/TeamPuchi/petit-infra) の compose から動いています。Phase 1(2026-07)に Docker の無い開発機で
> 書いたときは build 未確認でしたが、2026-09-23 に amd64・arm64 とも build と起動を確かめました(残りは [`docs/cloud/TODO.md`](./docs/cloud/TODO.md))。
> `:8765` で動く家 API のリポは TeamPuchi/petit-api(2026-09-26 に m5-petit-app から改名。コンテナ内のパスは `m5-petit-app` のまま)。

## 構成

```
docker-compose.yml           # dev: repos/ をビルドコンテキストにする
docker-compose.release.yml   # release: ビルド済みイメージ(将来用の雛形、Phase 4で運用開始予定)
Dockerfile.core               # ubuntu 24.04 + node(claude CLI) + uv + supercronic + tini + 焼き込んだコンポーネント
components.lock               # 焼き込むコンポーネントの固定 SHA(K14)
vendor/                       # vendor-components.sh の展開先(git 管理外・private の中身)
.env.example
cron/petit.cron               # supercronic用crontab
scripts/
  sync-repos.sh / .ps1        # 各コンポーネントを repos/ にclone/pull
  start.sh / .ps1             # sync-repos + docker compose up をまとめて実行
  petit.sh                    # update / logs / status / stop
  entrypoint.sh                # コンテナのエントリポイント(MCP設定生成 + supercronic + 家API)
  vendor-components.sh         # components.lock の版を vendor/ に展開・EC2 ホストへ渡す束を作る(手元で実行)
  install-components.sh        # build 中に venv を作る(Dockerfile.core から)
  gen-mcp-config.sh            # CHARACTER_IDS ごとに記憶 MCP・SNS-MCP の設定を作る(起動時)
  gen-skills.sh                # CHARACTER_IDS ごとにスキルの置き場を作る(起動時・自律行動の毎回)
  autonomous-action.sh         # 自律行動スクリプト(コンテナ内汎用版)
  run-for-each-character.sh    # CHARACTER_IDSを展開して各ジョブを実行する窓口
release/
  start-windows.bat / start-macos.command   # ダブルクリック起動(Phase 4で運用開始予定)
  README-for-users.md
sample-character/             # サンプルキャラ雛形(人格・実IPは含まない)
repos/.gitkeep                 # sync-repos.shの展開先
```

## 使い方(開発者向け・dev)

### 必要なもの

- Docker Desktop または Docker Engine
- Git
- 自分のClaudeアカウント(サブスクリプション or APIキー)

### セットアップ

```bash
git clone https://github.com/TeamPuchi/petit-env.git
cd petit-env
cp .env.example .env
# .env を編集: CHARACTER_IDS, M5_HOSTS_<ID> など
```

### 起動

```bash
./scripts/start.sh
```

内部で `scripts/sync-repos.sh`(コンポーネントリポジトリのclone/pull)→ `docker compose up --build` を実行します。

初回のみ、別ターミナルでClaude認証:

```bash
docker compose exec core claude login
```

起動後、ダッシュボードは `http://localhost:8765`。

### 日常操作

```bash
./scripts/petit.sh update   # コンポーネントを最新化してビルド・再起動
./scripts/petit.sh logs -f  # ログをフォロー
./scripts/petit.sh status   # コンテナの状態
./scripts/petit.sh stop     # 停止
```

更新はこちらの手動操作が主導権を持ちます(自動更新はしません。生きているぷちを日中に勝手に再起動しないため)。

## キャラクターを作る

`sample-character/` をコピーして、`.env` の `PETIT_DATA_DIR` に対応するホスト側ディレクトリの
`characters/<id>/` に配置してください。詳しくは [sample-character/README.md](./sample-character/README.md)。

## コンテナで動くもの

| # | コンポーネント | 動き方 |
|---|---|---|
| 1 | claude CLI + 自律行動 | supercronicが20分ごとに実行 |
| 2 | MCPサーバー群(memory / petit-sns / desire-system は自動生成、m5-mcp はキャラ固有設定) | claude CLIが都度spawn |
| 3 | 家 API(m5-petit-app, FastAPI :8765。petit-infra の Caddy が `/house/*` をここへ) | コンテナ内で常駐(落ちたら起こし直す) |
| 4 | 欲求システム更新(5分ごと・petit-desire の `desire-updater`)・日記(毎晩4:00)・記憶整理 | supercronicに集約 |
| 5 | 体験デーモン見張り | Phase 1時点ではプレースホルダー(下記「既知の制約」参照) |
| 6 | claude CLI の会話記録の消去(K21) | supercronicが毎日、`~/.claude/projects` 等の24時間より古いものを消す(`scripts/purge-claude-transcripts.sh`) |

> **claude CLI の会話記録は残さない**(K21・2026-09-24)。記憶は記憶 MCP(petit-memory。忘れる＝鍵ごと消す)が持つので、`~/.claude`(ボリューム `petit-claude-auth-<pid>`)の `projects/*.jsonl`・`history.jsonl` などは毎日24時間より古いものを消す。認証(`.credentials.json`)と設定は消さない。

> **はじめての日のチュートリアルが済むまで自律行動しない**(2026-09-27)。`autonomous-action.sh` は回ごとに家 API の `scripts/tutorial_state.py <id> gate` で家の表の `STATE#TUTORIAL` を見て、未完了なら何もせず抜ける(ログに1行)。状態を読めないときも今回は抜ける。欲求の5分ごとの更新は止めない。里親がまいぷち。の会話画面でお題を全部済ませると達成になり、次の回(最長20分後)から動きはじめる。運営が手で達成済みにするなら `tutorial_state.py <id> complete`、関所ごと外すなら `PETIT_TUTORIAL_GATE=0`。`PETIT_HOUSE_TABLE` が無い環境では関所は働かない。確かめ方: `bash scripts/tests/tutorial-gate.test.sh`。
>
> **メンテナンス中は、運営が選んだときだけ自律行動を休む**(2026-10-02)。運営が petit-infra の `scripts/maintenance.sh on --pause-petits` でメンテナンスモードを入れているあいだ、`autonomous-action.sh` は回ごとに家 API の `scripts/maintenance_state.py gate` で accounts 表の `CONFIG#maintenance` を見て、何もせず抜ける(ログに1行)。`--pause-petits` を付けないメンテナンスでは普段どおり動く。状態を読めないときも普段どおり動く。欲求の更新・日記・記憶の整理は止めない。関所ごと外すなら `PETIT_MAINTENANCE_GATE=0`。確かめ方: `bash scripts/tests/maintenance-gate.test.sh`。
>
> **まいぷち。の設定で動く時間・頻度・ON/OFF を決める**(akatsuki-petit#159)。チュートリアルの関所の次に、家 API の `scripts/settings_state.py <id> gate` が家の表の `STATE#SETTINGS`(まいぷち。の設定画面で変えるもの: 自律行動の ON/OFF・活動時間(平日・休日それぞれ3つまで)・今日の扱い(カレンダー通り=土日と日本の祝日が休日／今日だけ平日・休日とみなす=日付が変わると戻る)・活動時間の中の頻度(**既定は活動時間の枠ごとに1回**＝その日の活動時間の枠それぞれの中で1回ずつ。枠が3つなら1日3回。予定の時刻は枠の端すぎない所で日付とぷちで少しずつずれ、過ぎていてまだ動いていなければ動く。W15。「くわしく」で 20/40/60/120/180分に1回も選べる)・目とお喋り)を見て、0=動く/3=今回は休む を返す。まいぷち。でまだ決めていない項目は、これまでどおりキャラの `config/settings.json`(`active_hours`・`day_type_override`・`autonomous_enabled`)を読む。`autonomous_skip`(ダッシュボードの 20/40/60分)は W15 から読まない(まいぷち。で決めていなければ枠ごとに1回)。表を読めないときは今までの settings.json の判定に戻る(こちらは土日だけが休日で、祝日は見ない)。**活動時間の外では動かない**(まいぷち。で時間帯を決めていなくても、既定の枠 7-8・12-13・18-24 の外では動かない。表を読めないときの settings.json の判定も同じ。なぎさん 2026-10-03。それまでは外でも毎時0分に昼30%・夜10%の確率で動いていた)。cron は `*/20` のままで、頻度は関所が間引く(枠ごとに1回なら予定の時刻から20分以内に動く)。関所は読んだ印を表に残し、まいぷち。が「ぷちに届いたか」を出すのに使う。目・お喋りを切っていれば、プロンプトの「現在の制限」に足す。外すなら `PETIT_SETTINGS_GATE=0`。確かめ方: `bash scripts/tests/settings-gate.test.sh`。

> **ぷちは毎晩 4:00 に寝て、きのうの日記を書く**(akatsuki-petit#133・2026-09-27)。`run-for-each-character.sh diary` が家 API の `scripts/write_diary.py <id>` を呼び、ぷちがきのう(JST)の会話(`MSG#`)とその日の記憶(里親に見えるものだけ)を見返して、自分の口調で日記を書く(家の表の `DIARY#<date>`。まいぷち。の日記で読める)。書いたら会話のセッション(`/data/characters/<id>/state/.session-id.*`)を切り、次の会話ではいちばん最近の日記がシステムプロンプトに添えられる。会話も記憶も無い日は書かない。もう書いてある日は書き直さない(手で書き直すなら `write_diary.py <id> --date <YYYY-MM-DD> --overwrite`)。ログは `/data/logs/diary-cron.log` に1キャラ1行(本文は出さない)。`PETIT_HOUSE_TABLE` が無い環境では何もしない。確かめ方: `bash scripts/tests/diary-job.test.sh`。

> 記憶 MCP(`memory`)と SNS-MCP(`petit-sns`)の設定は `scripts/gen-mcp-config.sh` が起動時に `CHARACTER_IDS` のぷちごとに `/opt/petit/run/mcp/<id>.json` へ作る(秘密は書かない。`PETIT_SNS_INTERNAL_SECRET`・`ANTHROPIC_API_KEY`・AWS の認証情報はコンテナの env から claude 経由で MCP に引き継がれる)。`PETIT_HOUSE_TABLE` があれば記憶は DynamoDB(pk `P#<pid>`)、無ければ `/data/characters/<id>/memory.db`。
> 欲求 MCP(`desire-system`・petit-desire)も同じく自動生成する(2026-09-26)。`PETIT_HOUSE_TABLE` があれば家の表の `STATE#DESIRES`(家 API の `GET /petits/{pid}/mood` が読む行)、無ければ `/data/characters/<id>/data/desires.json`。5分ごとの更新(`run-for-each-character.sh desire`)と、自律行動のプロンプトに差し込む「いまの気分」(`desire-status`)も同じ env を使う。欲求の定義はキャラの `config/desire_config.json`、無ければ petit-desire の既定(仮置き)。
> **ぷちのスキル**(W11・2026-09-29)。Claude Code の Skills(`<置き場>/.claude/skills/<名前>/SKILL.md`。やり方の手順書)を、自律行動と会話の両方の claude に `--add-dir` で渡す。共通のスキルは petit-env の `skills/`(イメージの `/opt/petit/skills/`。いまは読書の `reading`)、ぷちだけのスキルは `/data/characters/<id>/skills/<名前>/SKILL.md`(同じ名前なら共通を置き換え・空の SKILL.md なら使わない。`sample-character/skills/README.md`)。`scripts/gen-skills.sh` が起動時と自律行動の毎回に `/opt/petit/run/skills/<id>/.claude/skills/` へまとめ、会話は家 API(petit-api main.py の `PETIT_SKILLS_DIR`)が同じ置き場を渡す。スキルを開く `Skill` と、調べもの用の `WebSearch`・`WebFetch`(なぎさん 2026-09-30)は自律行動の許可に入れてある。確かめ方: `bash scripts/tests/skills.test.sh`。

> **頭脳の原価を下げる**(W12・2026-09-30)。自律行動の claude には `--model`(`CLAUDE_MODEL`、既定 `claude-sonnet-5-5`＝Sonnet 5.5 の正式名。W15。W12 は別名 sonnet)・`--tools`(組み込みの道具は使うものだけ。`PETIT_AUTONOMOUS_TOOLS`。付けないと Bash・Task なども毎回載り、1回の入力が約2.6万トークン重い)を付ける。`--max-turns` は settings.json の `max_turns`(既定20)を `PETIT_AUTONOMOUS_MAX_TURNS`(既定5・0で頭打ちしない)で頭打ちにする(`MAX_TURNS` を渡せばそれ)。前の回の終わりの文脈(最後の呼び出しで読ませたトークン数。`state/.heartbeat-session-context` に数だけ残す)が `PETIT_AUTONOMOUS_CONTEXT_MAX`(既定30000・0で上限なし)を越えていたら、続きにせず新しいセッションで始める(元の仕組みは1日じゅう同じセッションを続けていた)。MCP の道具の説明は、多いと claude が後から探す(ToolSearch。1回に1ターン)。よく使うものは最初から載せる: 一覧は `scripts/preload-tools.txt` の1か所(`mcp__<サーバー>__<道具>`。選び方の数字もそこに。2026-10-03)。`gen-mcp-config.sh` がサーバーごとに分けて各 MCP サーバーの env `PETIT_PRELOAD_TOOLS` に入れ、家 API の house_mcp.py・petit-memory・petit-sns・petit-desire がその道具に `_meta` の `anthropic/alwaysLoad` を付ける(コンテナの env `PETIT_PRELOAD_TOOLS` で一時的に差し替え)。名前が実在して印が付いたかは本番で `/opt/petit/repos/m5-petit-app/.venv/bin/python /opt/petit/scripts/check-preload-tools.py /opt/petit/run/mcp/<id>.json --sizes`(claude は呼ばない。道具ごとの説明の重さも出る)。サーバーごと全部載せるのは `PETIT_MCP_ALWAYS_LOAD`(既定は空)。自律行動のプロンプトに「TODO を日誌にしない」「同じ remember を繰り返さない」「1つの出来事は1か所に」。会話・日記のモデル(`PETIT_CHAT_MODEL`・`PETIT_DIARY_MODEL`)と会話の `--tools`(`PETIT_CHAT_TOOLS`)は家 API が読む。確かめ方: `bash scripts/tests/brain-cost.test.sh`。

> それ以外の MCP サーバー(機体など)はキャラ固有の `config/autonomous-mcp.json` に足す(`memory`・`petit-sns`・`desire-system` の名前は使わない)。`scripts/autonomous-action.sh` は両方を `--mcp-config` に重ねて渡す。足したら `allowedTools` にも `mcp__<名前>__*` を追加する。

### コンポーネントのコードをどう渡すか(dev と release)

**dev はバインドマウント、開発が終わって結合テスト以降は焼き込み**、という方針(2026-09-22 決定)です。
`docker-compose.yml` はホストの `repos/` をコンテナの `/opt/petit/repos/<名前>` にバインドしますが、
コンテナ内の `uv run` が `.venv` を作れるように **`:ro` は付けていません**。そのかわり
`/opt/petit/repos/<名前>/.venv` にだけ匿名ボリュームを被せ、**ホスト側に `.venv` を作らせない**ようにしています
(ホストで作った venv はホストのアーキ・OS のものなので、ARM Linux コンテナでは使えないため)。
ソースの編集はそのまま即時反映され、venv だけがコンテナ側に閉じます。
dev の compose は `PETIT_REQUIRE_COMPONENTS=0` を渡すので、`vendor/` が空でも build は通ります。
結合テスト以降に使う「イメージへの焼き込み」は下の「ぷちコンテナへの焼き込み」を参照(T4・K14 で実装)。

### ぷちコンテナへの焼き込み(K14・2026-09-24)

> **コンテナの単位は「ぷち1体」（K19・2026-09-24 決定）。** クラウド(petit-infra)では 1 ぷちコンテナ＝
> `CHARACTER_IDS` に値を1つだけ持つのが前提(petit-infra の `compose/petits/petit-mio.env.example` は
> `CHARACTER_IDS=mio`)。複数ぷちを1コンテナに同居させる別仕様は作らない——同じ人が2体持つ場合も
> ぷちコンテナは2つに分ける(関係は accounts / relations 表で表す)。`CHARACTER_IDS` がカンマ区切りで
> 複数値を取れる仕組み自体(`scripts/run-for-each-character.sh` 等)は手元での複数キャラ開発用に残しており、
> クラウド版の前提を変えるものではない。

**取り込み方式**: `components.lock` に書いた**固定 SHA** を、GitHub に触れる手元(社長 PC)で
`scripts/vendor-components.sh` が `git archive` して `vendor/<名前>/` に展開し、それを build context に入れて `COPY` する。
build 時に EC2 ホストから git clone する方式は取らない——m5-petit-app・petit-sns は private で、
EC2 ホストに GitHub のトークンを置かない方針(petit-infra README §9.11)のため。build secret も要らない。

| 名前(`/opt/petit/repos/<名前>`) | 元 | 中で動くもの |
|---|---|---|
| `m5-petit-app` | `TeamPuchi/m5-petit-app`(develop の SHA) | 家 API(:8765・`PETIT_AUTH_MODE=gateway`・MQTT ブリッジ) |
| `petit-memory` | `TeamPuchi/petit-memory` | 記憶 MCP(`memory-mcp`。`--extra dynamo` で boto3＋cryptography＝K20 の暗号シュレッダーまで入る) |
| `petit-sns` | `TeamPuchi/petit-sns` の `sns-api/` | SNS-MCP(`petit-sns-mcp`。sns-api 本体は別コンテナ) |

- venv は build 中に作る(`scripts/install-components.sh`)。実行時に `uv sync` は走らない。
- petit-memory の torch は lock の版のまま **CPU 版 wheel** に差し替える(lock どおりだと Linux では CUDA 一式で数 GB)。
- `vendor/` が空のまま build すると**落ちる**(`PETIT_REQUIRE_COMPONENTS=1` が既定)。「build は通ったが中身が空」を作らないため。
- 入った版はイメージの `/opt/petit/components.txt` で見られる。版を上げるときは `components.lock` の SHA を書き換えて PR にする。
- 🔴 `vendor/` と `dist/` は git に入れない(`.gitignore` 済み)。このリポは public。

手元での build:

```bash
./scripts/vendor-components.sh
docker compose -f docker-compose.release.yml build
```

EC2 ホストへ渡すとき(petit-infra の `upload-src` は HEAD を `git archive` するので、vendor/ 込みで1コミットにした束を渡す):

```bash
./scripts/vendor-components.sh --bundle dist/petit-core-src
# 以降は petit-infra のチェックアウトで
./scripts/house-compose-deploy.sh upload-src ../petit-env/dist/petit-core-src petit-core
./scripts/house-compose-deploy.sh build <S3 URI> petit-core:latest . Dockerfile.core
```

起動時の流れ(`scripts/entrypoint.sh`・PID 1 は tini): MCP 設定の生成 → supercronic → 家 API(落ちたら 5 秒から倍々・最大 5 分で起こし直す。
出力は `/data/logs/dashboard.log` と `docker compose logs` の両方)→ 体験デーモン見張り。

### EC2 ホストでの petit-core イメージの build(K7・2026-09-23 実 build 確認済み)

EC2(t4g.small・arm64)の EC2 ホストに載せる `petit-core` イメージは、**レジストリを増やさず**、
EC2 ホスト自身の上で `docker compose build` してその場で使います。`ghcr.io` 等への push/pull は
まだ導入していません(将来 Phase 4 で切り替える余地は `PETIT_CORE_IMAGE` で残してあります)。

```bash
git clone https://github.com/TeamPuchi/petit-env.git
cd petit-env
./scripts/vendor-components.sh   # K14: 焼き込むコンポーネントを vendor/ へ(GitHub に触れる手元で)
docker compose -f docker-compose.release.yml build
```

これで `petit-core:latest` がホストの Docker にできます。タグ名は
[petit-infra](https://github.com/TeamPuchi/petit-infra) の `compose/docker-compose.yml`(petit-mio)が
参照する既定タグ(`${PETIT_CORE_IMAGE:-petit-core:latest}`)と揃えてあるので、続けて petit-infra 側の
`docker compose up -d` を実行すればそのまま拾われます(同じ Docker ホスト内なので pull は発生しません)。

> **arm64 の明示指定が要る場合**(buildx のデフォルトビルダーがホストネイティブでない等)は
> `docker buildx build --platform linux/arm64 -f Dockerfile.core -t petit-core:latest --load .` を使ってください。

**確認できたこと(このセッション: cloud sandbox・amd64・buildxのdocker-containerドライバでqemu-aarch64が
`exec format error` になり arm64 実行ができなかったため、amd64 で代替検証)**:

- `docker build` が通り、`docker run --entrypoint supercronic petit-core:amd64 -version` → `v0.2.47`
- `docker run --entrypoint claude petit-core:amd64 --version` → `2.1.267 (Claude Code)`
  （2026-09-29 に `CLAUDE_CODE_VERSION` を stable の `2.1.277` に上げた。`docker build` は未確認。Linux 版の本体で、会話・自律行動が使う旗
  `--print --system-prompt --output-format stream-json --verbose --input-format --thinking-display --max-turns --model --mcp-config
  --strict-mcp-config --allowedTools --add-dir --resume` を受け付けること、`--resume` の失敗の文言「No conversation found」と
  `result` 行の `session_id`・`total_cost_usd`・`num_turns`・`subtype`・`is_error` が前と同じことを確かめた。`--help` の中身は 2.1.267 と同じ）
  （2026-09-30・W15 に `2.1.285`(latest)に上げた。Sonnet 5.5 を知っているのが 2.1.284 からで、stable の 2.1.280 は `claude-sonnet-5-5` を
  「知らないモデル」として動かし、`total_cost_usd` が定価と違う・文脈の上限を 200K とみなす。`docker build` は未確認。手元(Windows 版)で
  `--model claude-sonnet-5-5` の会話・`--thinking-display summarized`(要約が入る)・`--resume` の続き・`--input-format stream-json`・
  `--tools`、Linux 版(WSL)で旗の受け付けと別名 sonnet → `claude-sonnet-5-5`・「No conversation found」を確かめた。`--help` の違いは
  `--client-data-url`・`--desktop` が増え、`--agents` がファイルも受けるようになっただけ。stream-json に `system` の `post_turn_summary`・
  `commands_changed`・`thinking_tokens` 行が出るが、家 API・台帳は `init` 以外の system 行を読まないので影響なし）
- `docker compose up -d` → `entrypoint.sh` が起動し、supercronicがcrontabを読み込んでジョブを実際に発火(1分間隔のテストcrontabで実行成功を確認)
- 5コンポーネントの `.venv` は匿名ボリュームにより `petit:petit` 所有になり、`uv run` が通る。ホスト側の `repos/<name>/.venv` は空のまま(T3の設計どおり)

EC2 ホスト(実 arm64)でも同じ手順で通る見込みですが、**実機での確認はまだ**です(EC2上でのbuild・
supercronic起動確認・EBSサイジングは [`docs/cloud/TODO.md`](./docs/cloud/TODO.md) の T7 を参照)。

**K14(2026-09-24)で T4 を実装**: 上の手順の前に `./scripts/vendor-components.sh` が要ります(無いと build が落ちる)。
家 API・記憶 MCP・SNS-MCP が焼き込まれ、amd64 で「`/petits` が 403(秘密なし)/401(秘密あり・アカウントなし)」
「`claude mcp list` で memory・petit-sns が Connected」まで確認済み。arm64 実機は未確認。

## OS対応

Windows / macOS / Linux、いずれもDocker Desktop(またはLinuxはDocker Engine)で動作する設計です。
M5デバイスとの接続はIP指定を基本とします(コンテナ内からmDNS `.local` ホスト名は解決できないことが多いため)。

音声(TTS/ASR)はCPUフォールバック、または音声なし構成で動く設計です。GPUを使う場合は外部マシンで
[m5-petit-speech](https://github.com/PetitOnes/m5-petit-speech) / [m5-petit-voice-recognition](https://github.com/PetitOnes/m5-petit-voice-recognition) を動かし、`.env` でURLを指定してください(この2つは TeamPuchi に fork が無いため上流を参照しています)。

## 既知の制約(Phase 1)

- **ビルド確認済み**。K7(2026-09-23)に amd64 で、同じ日に EC2(t4g・arm64)でも build が通り(petit-infra `docs/spikes.md` §2)、いまは EC2 のホストで動いています。残りは [`docs/cloud/TODO.md`](./docs/cloud/TODO.md)
- **ローカル版の notes-mcp / relations-mcp は、家 API の MCP サーバー `house` に移りました**。ノートは `note_*`(2026-09-27)、関係(相手ごとの好きなもの・苦手なこと・大事なこと・気持ち・親しさ)は `relation_*`(akatsuki-petit#171)。どちらも `autonomous-action.sh` の allowedTools に入っています。ローカルの `relations.json` をクラウドへ移す道具はまだありません
- **ローカル版の体験デーモン(experience-daemon)は置いていません**。手元の PC から M5 の `/sensors` を読んで「身体の記録」を残すものでしたが、クラウドでは機体の出来事が IoT Core 経由で家 API に届き、家 API が体の記録として残して、自律行動・会話の頭に「体の知らせ」として渡します(ぷちは house の `body_since` で読む。akatsuki-petit#117)。そのため見張り(`experience-watchdog.sh`)と5分ごとの cron は外しました
- `docker-compose.release.yml` / `release/*` は雛形です。 EC2 ホスト上でローカル build して `petit-core:latest` を作る運用にしました(上記「EC2 ホストでの petit-core イメージの build」参照・レジストリは未導入)。焼き込むのは m5-petit-app(リポは TeamPuchi/petit-api)・petit-memory・petit-sns(SNS-MCP)・petit-desire(欲求。2026-09-26 から)の4つで、petit-mcp・petit-scripts はまだ焼き込んでいません(クラウドでは機体は MQTT 経由のため)
- **EC2での実運用側の compose は [petit-infra](https://github.com/TeamPuchi/petit-infra) の `compose/docker-compose.yml` が正本**です。このリポジトリの compose 2本は開発用・雛形として残しています
- **petit-env ↔ petit-infra の環境変数**(T5): `CHARACTER_IDS` は petit-infra 側で入りました。K14 で petit-mio.env(雛形)をそのまま食わせて家 API が起動することを確認済み。残りは docs/cloud/TODO.md の T5

## ライセンス

Apache License 2.0. [LICENSE](./LICENSE) を参照。
