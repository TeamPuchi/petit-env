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
Dockerfile.core               # ubuntu 24.04 + node(claude CLI) + uv + supercronic
.env.example
cron/petit.cron               # supercronic用crontab
scripts/
  sync-repos.sh / .ps1        # 各コンポーネントを repos/ にclone/pull
  start.sh / .ps1             # sync-repos + docker compose up をまとめて実行
  petit.sh                    # update / logs / status / stop
  entrypoint.sh                # コンテナのエントリポイント(supercronic + ダッシュボード + 体験デーモン見張り)
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
| 2 | MCPサーバー群(m5-mcp / memory / desire-system) | claude CLIが都度spawn |
| 3 | 家コンテナのHTTPサービス(m5-petit-app, FastAPI :8765) | コンテナ内で常駐 |
| 4 | 欲求システム更新・記憶整理 | supercronicに集約 |
| 5 | 体験デーモン見張り | Phase 1時点ではプレースホルダー(下記「既知の制約」参照) |

> MCPサーバーを増やすとき(SNS連携など4本目以降)は `sample-character/config/autonomous-mcp.json` の `mcpServers` に足し、`scripts/autonomous-action.sh` の `allowedTools` にも対応する `mcp__<名前>__*` を追加する。

### コンポーネントのコードをどう渡すか(dev と release)

**dev はバインドマウント、開発が終わって結合テスト以降は焼き込み**、という方針(2026-09-22 決定)です。
`docker-compose.yml` はホストの `repos/` をコンテナの `/opt/petit/repos/<名前>` にバインドしますが、
コンテナ内の `uv run` が `.venv` を作れるように **`:ro` は付けていません**。そのかわり
`/opt/petit/repos/<名前>/.venv` にだけ匿名ボリュームを被せ、**ホスト側に `.venv` を作らせない**ようにしています
(ホストで作った venv はホストのアーキ・OS のものなので、ARM Linux コンテナでは使えないため)。
ソースの編集はそのまま即時反映され、venv だけがコンテナ側に閉じます。
結合テスト以降に使う「イメージへの焼き込み(`COPY`)」は**まだ未実装**で、別途対応します
(詳細は [`docs/cloud/TODO.md`](./docs/cloud/TODO.md) の T3・T4)。

### 家ホストでの petit-core イメージの build(K7・2026-09-23 実 build 確認済み)

EC2(t4g.small・arm64)の家ホストに載せる `petit-core` イメージは、**レジストリを増やさず**、
家ホスト自身の上で `docker compose build` してその場で使います。`ghcr.io` 等への push/pull は
まだ導入していません(将来 Phase 4 で切り替える余地は `PETIT_CORE_IMAGE` で残してあります)。

```bash
git clone https://github.com/TeamPuchi/petit-env.git
cd petit-env
docker compose -f docker-compose.release.yml build
```

これで `petit-core:latest` がホストの Docker にできます。タグ名は
[petit-infra](https://github.com/TeamPuchi/petit-infra) の `compose/docker-compose.yml`(house-0)が
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

家ホスト(実 arm64)でも同じ手順で通る見込みですが、**実機での確認はまだ**です(EC2上でのbuild・
supercronic起動確認・EBSサイジングは [`docs/cloud/TODO.md`](./docs/cloud/TODO.md) の T7 を参照)。

**まだ実運用には足りない点**: `Dockerfile.core` はコンポーネント5つの `COPY` をまだ実装していない(T4)ため、
上記でbuildしたイメージは core のガワ(cron・entrypoint・claude CLI・uv)だけが入った状態です。
起動はしますが、`/opt/petit/repos/` が空なので MCP サーバーもダッシュボードも動きません。
T4 が入るまでは petit-infra 側の house-0 も同様に「起動するが何もしない」状態になります。

## OS対応

Windows / macOS / Linux、いずれもDocker Desktop(またはLinuxはDocker Engine)で動作する設計です。
M5デバイスとの接続はIP指定を基本とします(コンテナ内からmDNS `.local` ホスト名は解決できないことが多いため)。

音声(TTS/ASR)はCPUフォールバック、または音声なし構成で動く設計です。GPUを使う場合は外部マシンで
[m5-petit-speech](https://github.com/PetitOnes/m5-petit-speech) / [m5-petit-voice-recognition](https://github.com/PetitOnes/m5-petit-voice-recognition) を動かし、`.env` でURLを指定してください(この2つは TeamPuchi に fork が無いため上流を参照しています)。

## 既知の制約(Phase 1)

- **ビルド確認済み(K7・2026-09-23)**。`docker build` / `docker compose up` は通り、supercronic・claude CLIの起動・cronジョブの発火・T3の匿名ボリューム所有権を確認済みです(cloud sandbox・amd64での代替検証。実機arm64での確認は未実施 → [`docs/cloud/TODO.md`](./docs/cloud/TODO.md) T7)
- **notes-mcp / relations-mcp はまだ含まれていません**。この2つのMCPサーバーのリポジトリがまだ無いため、`autonomous-action.sh` の allowedTools には含めていません(用意でき次第、追加予定)
- **体験デーモン(experience-daemon)相当の公開コンポーネントがまだ存在しません**。`scripts/experience-watchdog.sh` は対象ディレクトリが見つからなければ何もせずスキップする、将来のためのプレースホルダーです
- `docker-compose.release.yml` / `release/*` は雛形です。家ホスト上でローカル build して `petit-core:latest` を作る運用にしました(上記「家ホストでの petit-core イメージの build」参照・レジストリは未導入)。ただし `Dockerfile.core` にコンポーネントを焼き込む COPY はまだ未実装で(T4)、build自体は通ってもコンポーネントの中身は空のままです
- **EC2での実運用側の compose は [petit-infra](https://github.com/TeamPuchi/petit-infra) の `compose/docker-compose.yml` が正本**です。このリポジトリの compose 2本は開発用・雛形として残しています
- **petit-env ↔ petit-infra の環境変数が一部噛み合っていません**(T5)。特に `CHARACTER_IDS` を petit-infra 側の `compose/houses/house-0.env.example` が渡していないため、house-0 をそのまま起動すると cron ジョブが「CHARACTER_IDS が未設定。何もしない」で毎回スキップされます。petit-infra 側の対応が必要です

## ライセンス

Apache License 2.0. [LICENSE](./LICENSE) を参照。
