# petit-env クラウド版 v0 に向けた TODO

最終更新: 2026-09-23

このリポジトリは fork のため **GitHub Issues が無効**（fork の既定）で、Issue を立てられなかった。
そのためここで追う。Settings → Features → Issues を有効にすれば Issue に移せる。

一次資料は [`build-audit-2026-09-22.md`](./build-audit-2026-09-22.md)（行番号の出典つき）。

優先度: 🔴 v0 前に必須 / 🟡 やっておきたい / ⚪ v0 後でよい

| ID | 優先 | 件名 | 状態 |
|---|---|---|---|
| T1 | 🔴 | supercronic が arm64 で静かに壊れる | 適用済み・amd64で実build確認済み(→T7)。arm64実機は未確認 |
| T2 | 🔴 | Node 22 へ上げ、claude CLI と uv を固定 | 適用済み・実build確認済み(→T7) |
| T3 | 🔴 | dev の `:ro` × `uv run` を解く | 適用済み・実build確認済み(→T7) |
| T4 | 🔴 | `Dockerfile.core` に焼き込みの COPY を実装 | 未着手 |
| T5 | 🔴 | petit-env ↔ petit-infra の環境変数・認証の不一致 | 未着手。K7でCHARACTER_IDS欠落を再確認(petit-infra側の対応待ち) |
| T6 | 🟡 | 家コンテナ `:8765` の正本を決める | 判断待ち |
| T7 | 🔴 | EC2(t4g) で実 build と起動確認・EBS サイジング | cloud sandbox(amd64)で実施・完了。EC2実機(arm64)は未実施 |
| T8 | 🟡 | 埋め込みモデルのキャッシュを永続化 | petit-env 側は適用済み。petit-infra 側が残 |
| T9 | 🟡 | 小さな修正まとめ | 一部適用(`.dockerignore`・`grep -c`)。`VOLUME`・bind アドレスは残 |
| T10 | ⚪ | 音声2件の fork | 未着手 |

---

## T1 🔴 supercronic が arm64 で静かに壊れる（build は成功してしまう）

`Dockerfile.core:17` の URL が `supercronic-linux-amd64` 決め打ちで、`:16` の sha256 も amd64 のもの。
arm64 で build しても同じ amd64 バイナリを取るため **`sha256sum -c` が一致して通り、build は成功する**。

壊れるのは実行時。さらに `entrypoint.sh:5-6` の「各サービスの失敗でコンテナを落とさない」設計により、
**cron 4ジョブが全滅しても外からは正常に見える**。

実測済み:

| アセット | サイズ | sha256 |
|---|---|---|
| `supercronic-linux-amd64` | 16,906,330 B | `dcb1403c188a9438c47d4bba82a9c357fc9351ce91627fb2bae627f0f5becfc4` |
| `supercronic-linux-arm64` | 15,886,734 B | `e1124aa34294e2bb8ab7002f347f4363ba35097f3daf4d3c44e9d813c1fb2bb8` |

amd64 側の既存ピンは実測値と完全一致。壊れているのはアーキ分岐が無いことだけ。

**直し方**: `ARG TARGETARCH` で URL と sha256 を切り替える。`git apply --check` 済みのパッチが
[handoff](https://claude.ai/artifact/GLspa3zwts93CQEMYRv2nz) §03 にある。

**done**: `docker build` の成功では判定できない。`docker run --rm <image> supercronic -version` が通ること。

## T2 🔴 Node 22 へ上げ、claude CLI と uv のバージョンを固定

`Dockerfile.core:14` が `NODE_MAJOR=20` 固定だが、claude CLI は `engines.node >=22.0.0` を要求する。
npm の `engine-strict` は既定 false なので警告のみで**インストールは通る**＝実行時に転ぶ。

npm レジストリ実測: latest `2.1.278` は `>=22.0.0`、`>=18.0.0` だった最後は `2.1.98`、stable タグは `2.1.267`。
NodeSource の `node_22.x/nodistro` に arm64 パッケージが実在するので `NODE_MAJOR=22` で解決する見込み。

あわせて `Dockerfile.core:40` の claude CLI と `:58` の uv が**バージョン無指定**＝毎回 latest。
1家1コンテナで台数が増えると家ごとに別版が入る。supercronic だけ固定されている非対称を解消する。

**done**: `docker run --rm <image> claude --version` が通ること。

## T3 🔴 dev の `:ro` バインドマウント × `uv run` を解く

`docker-compose.yml` が 5コンポーネントを**すべて `:ro`** でマウントするのに、その全部に `uv run` を打っている
（`entrypoint.sh:25` / `run-for-each-character.sh:38,48` / `autonomous-mcp.json:5,13,20`）。
`uv run` は `.venv` を作って同期するので **`:ro` では作れない**。

`sync-repos.sh` がホスト側で `uv sync` する設計だが、それは**ホストのアーキ・OS の venv** になる。
Mac や x86 のホストで作ったものを ARM Linux コンテナでは使えない。

**方針（2026-09-22 なぎ確認済み）**

- 本番（EC2）: イメージに焼き込む → T4
- dev: bind mount のまま `:ro` を外し、**`.venv` のパスにだけ匿名ボリュームを被せる**

**done**: ホストに `.venv` を作らせずに `docker compose up` でダッシュボードと MCP が起動すること。

**実装済み（案A）**: `docker-compose.yml` の5コンポーネントから `:ro` を外し、
`/opt/petit/repos/<名前>/.venv` に匿名ボリュームを5本被せた。あわせて
`Dockerfile.core` でその5つの `.venv` を **petit 所有の空ディレクトリとして先に掘ってある**。
匿名ボリュームはイメージ側の同パスの所有者・パーミッションを引き継ぐので、
掘っていないとボリュームが root 所有で作られ、非root の petit が venv を作れないため。
**この所有権の引き継ぎは実 build で未確認**（T7 の確認項目に追加した）。

## T4 🔴 `Dockerfile.core` に焼き込みの COPY を実装

`Dockerfile.core:72-73` に「release: COPYで焼き込み」とコメントがあるだけで、
**実際に COPY する行が無い**。今ビルドすると `/opt/petit/repos/` が空のイメージができる。
`docker-compose.release.yml:2` も焼き込み済み前提で書かれているので、release 経路は現状成立しない。

T3 の方針どおり「結合テスト以降は焼き込み」なので、そのタイミングで実装する。

**done**: 焼き込んだイメージを `repos/` のマウント無しで起動して、MCP とダッシュボードが動くこと。

## T5 🔴 petit-env ↔ petit-infra の環境変数・認証の不一致

[petit-infra](https://github.com/TeamPuchi/petit-infra) の `compose/docker-compose.yml:26` が
「petit-core イメージは petit-env の `Dockerfile.core` を build して作る」と書いている一方、
渡す環境変数の形が噛み合っていない。

| | petit-env | petit-infra (`compose/houses/house-0.env.example`) |
|---|---|---|
| 機体の指定 | `M5_HOSTS_<ID大文字>`（キャラごと） | `M5_HOST`（家ごと・IoT Core 経由なら空） |
| MQTT | **無し** | `PETIT_IOT_ENDPOINT` |
| 家の識別 | `CHARACTER_IDS` | `PETIT_HOUSEHOLD_ID` |
| 認証 | `claude login` 前提（`.env.example:22-26`） | `ANTHROPIC_API_KEY`（SSM SecureString） |
| メディア | 無し | `PETIT_MEDIA_BUCKET` |

とくに **`M5_HOST` が空＝IoT Core 経由**という前提は petit-env 側に実装が無い。
`sample-character/config/autonomous-mcp.json:7` は `M5_HOST` に IP を直書きしたままになっている。

認証も、petit-infra 側は家ごとに API キーを SSM から配る設計なので、
監査で「家ごとに `claude login` の手動実行が要る」と書いた懸念はこちらで解消される見込み。

**done**: petit-infra の `house-0.env` をそのまま食わせてコンテナが起動すること。

## T6 🟡 家コンテナ `:8765` の正本を決める

`TeamPuchi/petit-app` は**クラウド版の Vite + React SPA**（`src/screens/*.tsx`、`dist-rel/` にビルド成果物）で、
`main.py` も `pyproject.toml` も無い。petit-infra の `50-web-hosting`（S3/CloudFront）に載る側。

一方 petit-infra の `compose/docker-compose.yml` は house-0 に `expose: 8765` を置き、
Caddy 経由で API Gateway（`60-api.yaml`）から引く構成になっている。
つまり**コンテナ側にも HTTP の口が要る**。現状それに当たるのは従来の FastAPI（`TeamPuchi/m5-petit-app`）。

そのため `repos/` の配置先はここだけ `m5-petit-app` のままにしてある。

**決めること**: クラウド版で家コンテナの `:8765` を
(a) `m5-petit-app` のまま使い続ける / (b) 新しい house API に置き換える / (c) SPA からの要求に合わせて作り直す。

## T7 🔴 EC2(t4g) で実 build と起動確認・EBS サイジング

監査時点で docker デーモンが無く**実 build は未実行**。T1〜T2 のパッチを当ててから 1回回す。

**合格条件は「build が通ること」ではない**（T1 がまさに build を通してしまう種類のため）:

```
docker run --rm --entrypoint supercronic <image> -version   # T1(entrypoint.shはCMDを無視するので--entrypointが要る)
docker run --rm --entrypoint claude <image> --version       # T2
docker run --rm --entrypoint uname <image> -m               # aarch64 であること
docker image inspect <image> --format '{{.Size}}'
```

T3 の匿名ボリュームの所有権も、ここで実物を見る:

```
docker compose up -d
docker compose exec core ls -ld /opt/petit/repos/petit-memory/.venv   # petit 所有であること
docker compose exec core sh -c 'cd /opt/petit/repos/petit-memory && uv run python -c "print(1)"'
ls repos/petit-memory/.venv                                           # ホスト側には出来ないこと
```

あわせて確認したいこと: arm64 で `uv.lock` の `nvidia-*` 15個と `triton` が解決対象外になるか。

**K7(2026-09-23)で実施・結果**: claude.ai cloud sandbox上(docker 29.3.1 + buildx、dockerd未起動だったため
root権限で起動)で実施。buildxのdocker-containerドライバ+qemu-aarch64(binfmt_misc)を試したが
`exec format error`でarm64エミュレーションが機能しなかった(サンドボックス側の制約とみられる。
Docker Hubのpullなど、dockerd自体のネットワークは通ったが、buildステップの実行コンテナ側は
arm64バイナリを動かせなかった)。そのため**amd64で代替検証**:

- `supercronic -version` → `v0.2.47` ✅ / `claude --version` → `2.1.267 (Claude Code)` ✅ / `uname -m` → `x86_64`(amd64で検証したため。arm64実機は未確認)
- image size: `docker images` 表示で 1.22GB(amd64)
- `docker compose up -d` → 起動・supercronicがcrontab読み込み。1分間隔のテストcrontabで実際にジョブが発火・成功することも確認(本番crontabは最短5分間隔のため、実発火はテスト用crontabで代替確認)
- `.venv` は `petit:petit` 所有・`uv run` 成功・ホスト側 `repos/petit-memory/.venv` は空 ✅(T3)
- なお、サンドボックスの透過proxyがTLS終端しておりcurl/npmが証明書検証で落ちたため、検証専用にproxyのCAをinstallするステップを**一時的にのみ**Dockerfileへ足して確認した(コミットはしていない。家ホスト/EC2は通常のインターネット直結なので、このワークアラウンドは不要と見込み)

**残作業**: EC2実機(t4g.small・arm64)での実 build・起動確認、EBSサイジング実測。

**EBS サイジング**: ［推測］合計 3〜4GB。**t4g のルート EBS 既定 8GB では余裕が少ない。**

| 要素 | 実測 / 見積 |
|---|---|
| Python wheel（memory 分のみ・DL サイズ） | 554 MB |
| 同、インストール後 | ［推測］1.2〜1.5 GB |
| claude CLI (linux-arm64) | 223 MiB |
| supercronic | 15 MB |
| ubuntu + apt + Node | ［推測］300〜400 MB |
| e5-base モデル（初回実行時に取得） | ［推測］1 GB 前後 |

`petit-mcp` / `petit-desire` の依存は未取得なのでこの見積もりに入っていない。

## T8 🟡 埋め込みモデルのキャッシュを永続化

memory MCP の埋め込みモデル `intfloat/multilingual-e5-base` はイメージに入らず、
初回実行時に HuggingFace から取得される（`petit-memory/src/memory_mcp/embedding.py:34-36` の遅延ロード）。
キャッシュ先 `~/.cache/huggingface` が `Dockerfile.core:70` の `VOLUME` にも
petit-infra の compose にも含まれていないため、**コンテナを作り直すたびに 1GB 級を再取得**する。

**実装済み（petit-env 側のみ）**: `Dockerfile.core` で `HF_HOME=/home/petit/.cache/huggingface` を
固定し（petit 所有でディレクトリも作成）、compose 2本が名前付きボリューム `petit-hf-cache` を
同じパスに被せる。`.env.example` に注意書きを1件追加した。

**残り**: **EC2 の正本である [petit-infra](https://github.com/TeamPuchi/petit-infra) の
`compose/docker-compose.yml` には同じボリュームがまだ無い**。1家1コンテナ × N家ぶん効くので、
そちらへの反映が要る（T5 と同じ範囲で拾う）。
uv のキャッシュ（`~/.cache/uv`）は未対応。こちらもコンテナを作り直すと wheel（memory 分だけで
554MB）を取り直すが、今回の範囲外。

## T9 🟡 小さな修正まとめ

- ~~**`.dockerignore` が無い**~~ — **対応済み**。リポジトリ直下に `.dockerignore` を追加した。T4 の焼き込み COPY を実装するときは `repos/` の除外を解除すること
- ~~**`autonomous-action.sh:233`**~~ — **対応済み**。`|| echo 0` を `|| true` にして、`-gt` 側の `2>/dev/null` も外した
- **`Dockerfile.core:70` の `VOLUME`** — `-v` 無し起動で匿名ボリュームができ、記憶と認証情報が迷子になる。常に明示マウントする運用に倒す
- **ダッシュボードの bind アドレス未確認** — `127.0.0.1` だと `EXPOSE 8765` が無意味になり、petit-infra の Caddy からも引けない。`m5-petit-app` の `main.py` を確認する

## T10 ⚪ 音声2件の fork

`m5-petit-speech` / `m5-petit-voice-recognition` は TeamPuchi に fork が無いため、
`sync-repos.sh` は上流（PetitOnes）を指したままにしてある。`WITH_SPEECH=1` のときだけ使う任意コンポーネント。

---

## 対象外（確認済み・対応不要）

監査で疑ったが問題が無かったもの。再調査しないでよい。

- **memory MCP の ARM 対応** — `uv.lock` のピン版に対し aarch64 wheel を実際に `pip download` した結果 **13/13 成功**（計 554MB、torch 2.12.1 が 406MB）。ソースビルドに落ちる依存はゼロ
- **`ubuntu:24.04`** — `linux/arm64/v8` を含む 6アーキの OCI image index
- **apt パッケージ名 8個** — すべて noble に実在
- **`COPY` 元 5ファイル** — すべて実在
- **`userdel -r ubuntu` → `useradd --uid 1000 petit`** — UID 衝突は fork 元の HEAD で解消済み
- **`PATH` と uv のインストール先** — 整合している
- **LAN 到達性** — petit-infra の `30-iot-core.yaml` で IoT Core（Thing・機体ポリシー・MQTT トピック
  `petit/<ThingName>/*`・shadow・jobs・`HouseHostPolicy`）が既に組まれており、機体はクラウドへ繋ぎに行く。
  petit-env 側に残る `M5_HOST=192.168.1.50` は旧オンプレ仕様の名残で、解消は T5 の範囲
