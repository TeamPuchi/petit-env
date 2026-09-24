# petit-env

## [English Page](./README_en.md)

M5 Petit(ぷち)をDockerで動かすためのumbrella実行環境です。[petit-mcp](https://github.com/TeamPuchi/petit-mcp) / [m5-petit-app](https://github.com/TeamPuchi/m5-petit-app) / [petit-memory](https://github.com/TeamPuchi/petit-memory) / [petit-desire](https://github.com/TeamPuchi/petit-desire) / [petit-scripts](https://github.com/TeamPuchi/petit-scripts) を1つのコンテナに組み合わせ、cron相当の自律行動・ダッシュボード・記憶整理などをまとめて起動します。

> このリポジトリは [PetitOnes/m5-petit-env](https://github.com/PetitOnes/m5-petit-env) の fork です。各コンポーネントも PetitOnes からの fork で、TeamPuchi 側では `m5-` 接頭辞を落とした名前に統一しています(`repos/` 配下のディレクトリ名も同じ)。

> ⚠️ **`m5-petit-app` と [`petit-app`](https://github.com/TeamPuchi/petit-app) は別物です。**
> このコンテナが `:8765` で動かすのは従来の FastAPI である `m5-petit-app` の方。
> `petit-app` はクラウド版の Vite + React SPA で、コンテナではなく S3/CloudFront に載ります
> ([petit-infra](https://github.com/TeamPuchi/petit-infra) の `50-web-hosting`)。
> ここだけ `m5-` 接頭辞を残しているのはそのためです。

> **Phase 1 (2026-07): authored, build-untested**
> このリポジトリは、Docker未導入の開発機の上で書かれました。`docker build` / `docker compose up` は
> まだ一度も実行できていません。検証できたのは以下のみです:
> - YAML構文(`python -c "import yaml; yaml.safe_load(...)"`)
> - シェルスクリプト構文(`bash -n`)
> - Dockerfileの静的な妥当性(目視・バージョン整合性の確認)
>
> 実機(Docker導入済み環境)でのビルド・起動確認はPhase 1の残タスクです。

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
  entrypoint.sh                # コンテナのエントリポイント(MCP設定生成 + supercronic + 家API + 体験デーモン見張り)
  vendor-components.sh         # components.lock の版を vendor/ に展開・EC2 ホストへ渡す束を作る(手元で実行)
  install-components.sh        # build 中に venv を作る(Dockerfile.core から)
  gen-mcp-config.sh            # CHARACTER_IDS ごとに記憶 MCP・SNS-MCP の設定を作る(起動時)
  autonomous-action.sh         # 自律行動スクリプト(コンテナ内汎用版)
  experience-watchdog.sh       # 体験デーモン見張り(Phase 1時点ではプレースホルダー)
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
| 2 | MCPサーバー群(memory / petit-sns は自動生成、m5-mcp / desire-system はキャラ固有設定) | claude CLIが都度spawn |
| 3 | 家 API(m5-petit-app, FastAPI :8765。petit-infra の Caddy が `/house/*` をここへ) | コンテナ内で常駐(落ちたら起こし直す) |
| 4 | 欲求システム更新・記憶整理 | supercronicに集約 |
| 5 | 体験デーモン見張り | Phase 1時点ではプレースホルダー(下記「既知の制約」参照) |

> 記憶 MCP(`memory`)と SNS-MCP(`petit-sns`)の設定は `scripts/gen-mcp-config.sh` が起動時に `CHARACTER_IDS` のぷちごとに `/opt/petit/run/mcp/<id>.json` へ作る(秘密は書かない。`PETIT_SNS_INTERNAL_SECRET`・`ANTHROPIC_API_KEY`・AWS の認証情報はコンテナの env から claude 経由で MCP に引き継がれる)。`PETIT_HOUSE_TABLE` があれば記憶は DynamoDB(pk `P#<pid>`)、無ければ `/data/characters/<id>/memory.db`。
> それ以外の MCP サーバー(機体・欲求など)はキャラ固有の `config/autonomous-mcp.json` に足す(`memory`・`petit-sns` の名前は使わない)。`scripts/autonomous-action.sh` は両方を `--mcp-config` に重ねて渡す。足したら `allowedTools` にも `mcp__<名前>__*` を追加する。

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
| `petit-memory` | `TeamPuchi/petit-memory` | 記憶 MCP(`memory-mcp`。DynamoDB は `--extra dynamo`) |
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

- **ビルド確認済み(K7・2026-09-23)**。`docker build` / `docker compose up` は通り、supercronic・claude CLIの起動・cronジョブの発火・T3の匿名ボリューム所有権を確認済みです(cloud sandbox・amd64での代替検証。実機arm64での確認は未実施 → [`docs/cloud/TODO.md`](./docs/cloud/TODO.md) T7)
- **notes-mcp / relations-mcp はまだ含まれていません**。この2つのMCPサーバーのリポジトリがまだ無いため、`autonomous-action.sh` の allowedTools には含めていません(用意でき次第、追加予定)
- **体験デーモン(experience-daemon)相当の公開コンポーネントがまだ存在しません**。`scripts/experience-watchdog.sh` は対象ディレクトリが見つからなければ何もせずスキップする、将来のためのプレースホルダーです
- `docker-compose.release.yml` / `release/*` は雛形です。 EC2 ホスト上でローカル build して `petit-core:latest` を作る運用にしました(上記「EC2 ホストでの petit-core イメージの build」参照・レジストリは未導入)。焼き込むのは m5-petit-app・petit-memory・petit-sns(SNS-MCP)の3つだけで、petit-mcp・petit-desire・petit-scripts はまだ焼き込んでいません(クラウドでは機体は MQTT 経由のため)
- **EC2での実運用側の compose は [petit-infra](https://github.com/TeamPuchi/petit-infra) の `compose/docker-compose.yml` が正本**です。このリポジトリの compose 2本は開発用・雛形として残しています
- **petit-env ↔ petit-infra の環境変数**(T5): `CHARACTER_IDS` は petit-infra 側で入りました。K14 で petit-mio.env(雛形)をそのまま食わせて家 API が起動することを確認済み。残りは docs/cloud/TODO.md の T5

## ライセンス

Apache License 2.0. [LICENSE](./LICENSE) を参照。
