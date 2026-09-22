# petit-env ビルド監査（2026-09-22）

クラウド版ぷち v0 で、この箱を EC2（ARM＝t4g 想定）に 1家1コンテナで載せる前に、
**費用ゼロで分かることを全部潰す**ための監査。EC2 はまだ立てていない。

このメモの書き方:

- 出典は `ファイル:行番号` で示す。行番号は下記「監査した版」時点のもの。
- 実際に確認した事実と、確認していない推測を分ける。推測には ［推測］ を付ける。
- 調べたが分からなかったものは「未確認」と明記する。

---

## 0. 監査した版 / fork の素性

| 項目 | 値 |
|---|---|
| 対象リポジトリ | `TeamPuchi/petit-env`（`PetitOnes/m5-petit-env` の fork） |
| 監査時の HEAD | `1d51428` "Fix useradd conflict with ubuntu:24.04 default user" |
| **fork 元の最終コミット日** | **2026-07-06**（`1d51428`, author `PetitOnes <petitones01@gmail.com>`, 2026-07-06T15:52:57+09:00） |
| **TeamPuchi 側の差分** | **無し**。`main` の全コミット（2本）が上流名義（`RRYZ09` / `PetitOnes`）で、TeamPuchi・なぎ名義のコミットは 1本も無い |
| ブランチ | `main` のみ（`origin/main` と一致） |

つまり **この fork は 2026-07-06 の上流をそのまま持っているだけ**で、fork 後（2026-09-22）に手は入っていない。
上流 `PetitOnes/m5-petit-env` がその後さらに進んでいるかどうかは、PetitOnes org を触らない方針のため **未確認**。

リポジトリ自身も未検証であることを 3箇所で自己申告している:

- `Dockerfile.core:8-10` … 「Phase 1 (2026-07): authored, build-untested … `docker build` はまだ一度も実行できていない」
- `docker-compose.yml:3-4` … 同上
- `README.md:109`（既知の制約）… 「**ビルド未検証**」

---

## 1. このセッションで docker が使えたか → **使えなかった（実 build 未実行）**

```
$ docker version
Client: Docker Engine - Community  Version: 29.3.1  OS/Arch: linux/amd64
failed to connect to the docker API at unix:///var/run/docker.sock:
  dial unix /var/run/docker.sock: connect: no such file or directory
```

docker **クライアントは入っているがデーモンが無い**ため、`docker buildx build --platform linux/amd64`
および `linux/arm64` は **未実行**。所要時間・実際に落ちる行は実測できていない。

代わりに、以下を実施した:

1. `Dockerfile.core` 全 77行の行単位の静的監査（§2）
2. **ビルドが外部から取ってくる実体を、ネットワーク越しに実物で確認**（§3）
   - ベースイメージの arm64 manifest
   - supercronic の arm64 アセットの実在と sha256 実測
   - NodeSource apt リポジトリの arm64 パッケージ実在
   - claude CLI の npm メタデータ（`engines` / プラットフォーム別パッケージ）
   - memory MCP の Python 依存の **aarch64 wheel を実際に `pip download` して取得**

このセッションの実行環境は `x86_64` / Python 3.11 / Node 22.22.2。
HTTPS はエージェントプロキシ経由だが、`pypi.org` `files.pythonhosted.org` `registry.npmjs.org` は
プロキシ除外で直通。GitHub の **API**（`api.github.com`）はリポジトリスコープ外で 403 だが、
**リリースアセットのダウンロード**（`github.com/.../releases/download/...`）は通った。

---

## 2. build が落ちうる／その先で壊れうる箇所

（監査してみると、**いちばん危ないもの（A1）は build を落とさずに通ってしまう**種類だった。
「`docker build` が成功する」を合格条件にすると取りこぼすので、実行時に壊れるものも同じ表に並べた。）

重大度: **A = arm64 で確実に壊れる（最優先）** / **B = build は通るが要修正** / **C = build 後、実行時に止まる**

| # | 重 | 箇所 | 内容 |
|---|---|---|---|
| A1 | A | `Dockerfile.core:16,17,43-45` | supercronic の URL と sha256 が **amd64 決め打ち**。arm64 では **build が通ってしまい、実行時に cron が全滅する** |
| B1 | B | `Dockerfile.core:14,37-40` | Node 20 固定。claude CLI 最新は **`engines.node >=22.0.0`** |
| B2 | B | `Dockerfile.core:40` | `npm install -g @anthropic-ai/claude-code` が **バージョン無指定**（再現性なし） |
| B3 | B | `Dockerfile.core:58` | uv を `curl \| sh` で **バージョン無指定**インストール（再現性なし。arm64 対応自体は OK） |
| B4 | B | リポジトリ直下 | **`.dockerignore` が無い**。build context に `repos/`（数GB）と `.env` が丸ごと入る |
| B5 | B | `Dockerfile.core:70` | `VOLUME` 宣言により `-v` 無し起動で匿名ボリュームが生まれ、データが迷子になりやすい |
| B6 | B | `Dockerfile.core` 全体 | イメージが**非常に大きくなる**（§3.5）。t4g のルート EBS 既定 8GB では足りない見込み |
| C1 | C | `docker-compose.yml:23-27` × `entrypoint.sh:27` ほか | `:ro` バインドマウントに対して `uv run` → **venv を作れない** |
| C2 | C | `scripts/sync-repos.sh:7` ほか | コンポーネント取得先が **PetitOnes 固定**（§4） |
| C3 | C | `docker-compose.release.yml:6` | `ghcr.io/petitones/m5-petit-core:latest` は**未公開**（`docker-compose.release.yml:3` が自認） |
| C4 | C | `scripts/autonomous-action.sh:233` | `grep -c ... \|\| echo 0` が 0件時に **2行**返し、直後の数値比較が壊れる |
| C5 | C | `scripts/entrypoint.sh:24-32` | ダッシュボードが `0.0.0.0` を listen するか **未確認**（`m5-petit-app` が手元に無い） |

**合計 12件**（A: 1 / B: 6 / C: 5）。

### A1 — supercronic が amd64 決め打ち（arm64 で静かに壊れる。最優先）

```dockerfile
16  ARG SUPERCRONIC_SHA256=dcb1403c188a9438c47d4bba82a9c357fc9351ce91627fb2bae627f0f5becfc4
17  ARG SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64
...
43  RUN curl -fsSL -o /usr/local/bin/supercronic "${SUPERCRONIC_URL}" \
44      && echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - \
45      && chmod +x /usr/local/bin/supercronic
```

ファイル名 `supercronic-linux-amd64` が URL に直接埋まっており、`TARGETARCH` 等のビルド引数を一切見ていない。
arm64 で build しても URL は変わらないので、**amd64 バイナリを落として arm64 イメージに焼き込む**。

ここが厄介なのは、**この行では build が落ちない**こと:

- 落としてくるのは amd64 バイナリ。
- `Dockerfile.core:16` の sha256 も amd64 のもの。
- よって 44行目の `sha256sum -c` は **一致して通る**。45行目の `chmod +x` も通る。
- **build は成功し、壊れていることに気づけない。**

壊れるのは実行時で、`entrypoint.sh:17` が `supercronic` を起動した瞬間に
`exec format error` になる［推測: ELF アーキ不一致の一般的な挙動。実機未検証］。
しかも `entrypoint.sh:5-6` の設計どおり **各サービスの失敗はコンテナを落とさない**ため、
コンテナは元気に上がったまま `/data/logs/supercronic.log` の中だけでエラーになる。
= **自律行動・欲求更新・記憶整理（`cron/petit.cron:13-24` の全4ジョブ）が丸ごと動かないのに、
外からは正常に見える。**

これが「build が落ちうる箇所」ではなく「最優先」である理由。
実 build で `docker build` が成功しても、この件が直ったことにはならない。
検証は `docker run --rm <image> supercronic -version` のように**実際に起動して**行う必要がある。

実測（このセッションで両アーキのバイナリを実際にダウンロードして計測）:

| アセット | サイズ | sha256 |
|---|---|---|
| `supercronic-linux-amd64` | 16,906,330 B | `dcb1403c188a9438c47d4bba82a9c357fc9351ce91627fb2bae627f0f5becfc4` |
| `supercronic-linux-arm64` | 15,886,734 B | `e1124aa34294e2bb8ab7002f347f4363ba35097f3daf4d3c44e9d813c1fb2bb8` |

- **`Dockerfile.core:16` の amd64 sha256 は実測値と完全一致**。pin 自体は正しい。壊れているのはアーキ分岐が無いことだけ。
- **`supercronic-linux-arm64` は v0.2.47 に実在する**（HTTP 200・15.1MiB）。上の sha256 をそのまま arm64 用 pin に使える。

修正方針（実装は本 PR では行わない）: `ARG TARGETARCH` を受けて URL と sha256 をアーキごとに切り替える。
`docker buildx` は `TARGETARCH` に `amd64` / `arm64` を渡すので、supercronic のアセット名とそのまま一致する。

### B1 — Node 20 と claude CLI の `engines` 不一致

```dockerfile
14  ARG NODE_MAJOR=20
...
37  RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
38      && apt-get install -y --no-install-recommends nodejs \
40      && npm install -g @anthropic-ai/claude-code
```

npm レジストリを実際に引いた結果:

| 項目 | 値 |
|---|---|
| `@anthropic-ai/claude-code` latest | `2.1.278` |
| latest の `engines.node` | **`>=22.0.0`** |
| `engines.node` が `>=18.0.0` だった最後のバージョン | `2.1.98` |
| `>=22.0.0` になっているバージョン数 | 72 |
| dist-tags | `stable: 2.1.267` / `latest: 2.1.278` |

`Dockerfile.core:14` の Node 20 では **engines を満たさない**。
npm の `engine-strict` は既定 false なので `npm warn EBADENGINE` を出して**インストール自体は続行する**［推測: 既定値に基づく。実 build で未検証］。
つまり build は通り、**実行時に claude CLI が動かないリスク**として残る。
postinstall (`node install.cjs`) が Node 22 前提の構文を使っていないかは **未確認**。

あわせて確認した NodeSource 側:

- `https://deb.nodesource.com/setup_20.x` は **amd64 / arm64 のみ対応**を明記（スクリプト 78-80行目で他アーキは `handle_error`）。arm64 は OK。
- Node 20 は 2026-04 に EOL だが、**apt リポジトリにはまだ残っている**: `node_20.x/nodistro` の arm64 に `20.20.2-1nodesource1` ほかが実在（HTTP 200）。
- 乗り換え先の `node_22.x/nodistro` arm64 にも `22.23.2-1nodesource1` ほかが実在。**`NODE_MAJOR=22` にするだけで解決する見込み**。

claude CLI の arm64 対応そのものは問題なし:

- `optionalDependencies` に `@anthropic-ai/claude-code-linux-arm64` があり、`2.1.278` が実在（`os: ["linux"] / cpu: ["arm64"]`）。
- ただし **展開後サイズ 234,021,698 B（約 223MiB）**。イメージ肥大の主因のひとつ（B6）。

### B2 / B3 — バージョン無指定の外部取得

- `Dockerfile.core:40` `npm install -g @anthropic-ai/claude-code` … タグ無し＝毎回 latest。
  1家1コンテナで台数が増えると、**家ごとに違う claude CLI が入る**。supercronic は `Dockerfile.core:15-16` できちんと version + sha256 を固定しているのに、CLI だけ固定されていないのは非対称。
- `Dockerfile.core:58` `curl -LsSf https://astral.sh/uv/install.sh | sh` … 同様に latest。
  インストーラの中身を確認したところ **`aarch64-unknown-linux-gnu` / `aarch64-unknown-linux-musl` を扱えるので arm64 対応は問題なし**。
  インストール先は `$XDG_BIN_HOME` → `$HOME/.local/bin`（インストーラ 129-131行目）で、
  `Dockerfile.core:22` の `PATH=/home/petit/.local/bin:...` と**一致している**（ここは正しい）。

### B4 — `.dockerignore` が無い

リポジトリ直下に `.dockerignore` が存在しない。`docker-compose.yml:8` の `context: .` は
リポジトリ全体を build context として daemon に送るため:

- `.gitignore:2` で git 管理外にしている `repos/*`（`sync-repos.sh` が展開する各コンポーネント。`uv sync` 後は `.venv` 込みで数GB）が毎回転送される。
- `.gitignore:6` の `.env`（**秘密が入る想定**）も build context に入る。
  `Dockerfile.core` は `COPY . .` をしていない（`Dockerfile.core:61-65` で個別ファイルのみ COPY）ので
  **イメージには焼き込まれない**が、context に載ること自体は避けたい。

### B5 — `VOLUME` 宣言

```dockerfile
70  VOLUME ["/data", "/home/petit/.claude"]
```

`docker-compose.yml:21-22` では名前付きボリュームを明示しているので dev では問題ない。
しかし `docker run` を素で叩くと匿名ボリュームが 2つでき、**キャラの記憶と claude の認証情報が迷子になる**。
EC2 で 1家1コンテナを回す際、ここは必ず明示マウントに倒す運用にする必要がある。

### B6 — イメージサイズ

§3.5 に実測ベースの見積もりを置いた。**wheel だけで 554MiB、claude CLI で +223MiB**。
t4g のルート EBS を既定 8GB のままにすると、イメージ + レイヤ + モデルキャッシュ + `/data` で足りなくなる見込み［推測: 実 build 未実施のため確定値ではない］。

### C1 — `:ro` バインドマウント × `uv run`（実行時に確実に詰まる）

`docker-compose.yml:23-27` は 5つのコンポーネントを **すべて `:ro`** でマウントする:

```yaml
23      - ./repos/m5-petit-mcp:/opt/petit/repos/m5-petit-mcp:ro
24      - ./repos/m5-petit-app:/opt/petit/repos/m5-petit-app:ro
25      - ./repos/m5-petit-memory:/opt/petit/repos/m5-petit-memory:ro
26      - ./repos/m5-petit-desire:/opt/petit/repos/m5-petit-desire:ro
27      - ./repos/m5-petit-scripts:/opt/petit/repos/m5-petit-scripts:ro
```

一方、この 5つに対して実行されるのは全部 `uv run`:

| 呼び出し元 | 行 | コマンド |
|---|---|---|
| `scripts/entrypoint.sh` | 27 | `cd /opt/petit/repos/m5-petit-app && exec uv run python main.py` |
| `scripts/run-for-each-character.sh` | 38 | `cd .../m5-petit-desire && uv run python desire_updater.py` |
| `scripts/run-for-each-character.sh` | 48 | `cd .../m5-petit-memory && uv run python scripts/sleep.py` |
| `sample-character/config/autonomous-mcp.json` | 5, 13, 20 | `uv run --directory /opt/petit/repos/...` |

`uv run` は既定でプロジェクト直下に `.venv` を作って同期する。**マウントが `:ro` なので作れない。**

`scripts/sync-repos.sh:33-36` が **ホスト側で** `uv sync` を走らせて `.venv` を先に作る設計になっているが、これは:

1. **ホストのアーキ・OS の venv** になる。Mac や x86 のホストで作った `.venv` を ARM Linux コンテナで使うことはできない。
2. EC2 ARM 上でホスト側 `uv sync` をするなら、結局ホストに uv と Python ツールチェインが要る（コンテナに閉じ込める意味が薄れる）。

クラウド版では **`:ro` をやめる / venv をコンテナ内の書き込み可能な場所に置く / そもそもイメージに焼き込む** のいずれかに倒す必要がある。v0 の設計判断として大きいので、ここは修正 PR の前になぎの判断を仰ぎたい。

### C4 — `autonomous-action.sh:233` の数値比較バグ

```bash
233      UNREAD_COUNT=$(python3 "$SCRIPTS_DIR/list_unread_mail.py" "$CHARACTER_ID" 2>/dev/null | grep -c "^  from_\|^  to_" || echo 0)
234      if [ "$UNREAD_COUNT" -gt 0 ] 2>/dev/null; then
```

`grep -c` は 0件でも標準出力に `0` を出したうえで **終了ステータス 1** を返す。
よって `|| echo 0` が追加で発火し、`UNREAD_COUNT` が `0\n0` になる。
234行目の `-gt` は「整数でない」エラーになり、`2>/dev/null` に飲まれて偽扱い。
**未読0件のときは結果的に意図どおり動く**が、エラーを握り潰しているだけなので直したほうがよい。軽微。

### 問題が無いことを確認した箇所

誤解を避けるため、疑ったが**白**だったものも残す。

- `Dockerfile.core:11` `FROM ubuntu:24.04` … Docker Hub の manifest を実際に引いた結果、
  **`linux/arm64/v8` を含む 6アーキの OCI image index**（`linux/amd64`, `linux/arm/v7`, `linux/arm64/v8`, `linux/ppc64le`, `linux/riscv64`, `linux/s390x`）。arm64 OK。
- `Dockerfile.core:25-34` の apt パッケージ名 … `ca-certificates` `curl` `git` `jq` `python3` `python3-venv` `python3-pip` `tzdata` の**8つすべて noble に実在**（packages.ubuntu.com が全部 HTTP 200）。
- `Dockerfile.core:61-65` の **COPY 元 5ファイルすべて実在**
  （`cron/petit.cron`, `scripts/entrypoint.sh`, `scripts/autonomous-action.sh`, `scripts/experience-watchdog.sh`, `scripts/run-for-each-character.sh`）。
  `scripts/petit.sh` `scripts/start.sh` `scripts/sync-repos.*` はホスト側専用なので COPY されていないのが正しい。
- `Dockerfile.core:49-52` の `userdel -r ubuntu` → `useradd --uid 1000 petit` … これが HEAD コミット `1d51428` の修正内容そのもの。`|| true` 付きで冪等。UID 1000 の衝突は解消済み。
- `Dockerfile.core:22` の `PATH` … uv（`~/.local/bin`）と整合。§B3 参照。
- `Dockerfile.core:17` の `ARG` 内での `${SUPERCRONIC_VERSION}` 参照 … 同一ステージ内の ARG 参照なので展開される。
- `scripts/entrypoint.sh:11` が `/data/logs` を作ってから `:17` で supercronic を起動している … `cron/petit.cron:13-24` の各ジョブが `/data/logs/*.log` に追記する順序として正しい。

---

## 3. ARM（aarch64）依存の実測

### 3.1 ベースイメージ

`ubuntu:24.04` は `linux/arm64/v8` を持つ。**問題なし**（§2 末尾）。

### 3.2 claude CLI

`@anthropic-ai/claude-code-linux-arm64@2.1.278` が実在。**arm64 対応済み**。
ただし Node 22 が要る（B1）。

### 3.3 supercronic

`supercronic-linux-arm64` が v0.2.47 に実在。sha256 実測済み（A1 の表）。**アーキ分岐を足すだけで解決**。

### 3.4 memory MCP の Python 依存 — **aarch64 wheel は全部ある**

memory MCP の実体は本リポジトリに無い（`.gitignore:2` で `repos/*` は git 管理外）。
そこで **`TeamPuchi/petit-memory`（public fork）を clone して `pyproject.toml` と `uv.lock` を直接読んだ**。

- `TeamPuchi/petit-memory` HEAD: `PetitOnes <petitones01@gmail.com>` 2026-07-06 "Add upstream attribution (lifemate-ai/embodied-claude, MIT)"
- 直接依存（`pyproject.toml:11-19`）: `mcp>=1.0.0`, `python-dotenv>=1.0.0`, `Pillow>=10.0.0`, `sentence-transformers>=2.0.0`, `rank-bm25>=0.2.2`, `sudachipy>=0.6.10`, `sudachidict-core>=20260116`
- `requires-python = ">=3.10"`（`pyproject.toml:10`）。ubuntu:24.04 の system python は 3.12。
- 埋め込みモデルは **`intfloat/multilingual-e5-base`**（`src/memory_mcp/config.py:18,29`, `src/memory_mcp/embedding.py:26`）。`SentenceTransformer` の遅延ロード（`embedding.py:34-36`）。
- `uv.lock` は 107パッケージを固定。`faiss` は**入っていない**（ベクタ検索は e5 + `rank-bm25` + SQLite の構成）。

`uv.lock` のピン版に対し、**`pip download --only-binary=:all: --platform manylinux_2_28_aarch64 --platform manylinux2014_aarch64 --python-version 3.12` を実際に実行**した結果:

| パッケージ | ピン版 | aarch64 wheel | 取得サイズ |
|---|---|---|---|
| `torch` | 2.12.1 | **OK** `cp312-cp312-manylinux_2_28_aarch64` | 406.6 MB |
| `sudachidict-core` | 20260428 | OK（`py3-none-any`） | 68.9 MB |
| `scipy` | 1.18.0 | **OK** `cp312-...-manylinux_2_28_aarch64` | 32.4 MB |
| `numpy` | 2.5.1 | **OK** `cp312-...-manylinux_2_28_aarch64` | 14.5 MB |
| `transformers` | 5.13.0 | OK（`py3-none-any`） | 11.0 MB |
| `scikit-learn` | 1.9.0 | **OK** `cp312-...-manylinux_2_28_aarch64` | 8.4 MB |
| `Pillow` | 12.3.0 | **OK** `cp312-...-manylinux_2_28_aarch64` | 6.0 MB |
| `tokenizers` | 0.22.2 | **OK** `cp39-abi3-manylinux2014_aarch64` | 3.1 MB |
| `sudachipy` | 0.6.11 | **OK** `cp312-cp312-manylinux2014_aarch64` | 1.5 MB |
| `sentence-transformers` | 5.6.0 | OK（`py3-none-any`） | 0.6 MB |
| `safetensors` | 0.8.0 | **OK** `cp310-abi3-manylinux2014_aarch64` | 0.5 MB |
| `mcp` | 1.28.1 | OK（`py3-none-any`） | 0.2 MB |
| `rank-bm25` | 0.2.2 | OK（`py3-none-any`） | 0.0 MB |

**13/13 すべて取得成功。合計 554 MB。ソースビルドに落ちる依存はゼロ。**

→ **「memory MCP は ARM で動かないかもしれない」という当初の懸念は、依存解決レベルでは否定された。**
`torch` 2.12.1 は aarch64 の manylinux_2_28 wheel を正式に配っている。

残る未確認（依存解決では分からないこと）:

- **実際に import して推論が通るか**は未確認。wheel が取れることと動くことは別。
- `uv.lock` には `nvidia-*` 15個と `triton` が入っているが、これらは CUDA 用でマーカーにより
  **linux x86_64 のみ**［推測: 一般的な torch の lock 構成に基づく］。arm64 では解決対象外になるはず。実 build で確認したい。
- **e5-base のモデル本体はイメージに入っておらず、初回実行時に HuggingFace から落ちる**
  （`embedding.py:34-36` の遅延ロード）。つまり **EC2 の初回起動に外向き HTTPS とダウンロード時間が要る**。
  multilingual-e5-base は 278M パラメータ級なので実体 1GB 前後［推測］。キャッシュ先（`~/.cache/huggingface`）は
  `Dockerfile.core:70` の `VOLUME` に含まれていないため、**コンテナを作り直すたびに再ダウンロードになる**。要対処。

### 3.5 サイズ見積もり（EBS サイジング用）

| 要素 | 実測 / 見積 |
|---|---|
| Python wheel（memory MCP 分のみ） | 554 MB（ダウンロードサイズ） |
| 同、インストール後 | ［推測］1.2〜1.5 GB |
| claude CLI（linux-arm64） | 223 MiB（展開後・npm 公称 `unpackedSize`） |
| supercronic | 15 MB |
| ubuntu:24.04 + apt パッケージ + Node | ［推測］300〜400 MB |
| e5-base モデル（初回実行時に取得） | ［推測］1 GB 前後 |
| **合計** | ［推測］**3〜4 GB**（`/data` のキャラデータ・ログは別） |

**t4g のルート EBS 既定 8GB では、1家1コンテナでも余裕が少ない。** 実 build で確定値を取るべき。
なお `m5-petit-app` / `m5-petit-mcp` / `m5-petit-desire` の依存は未取得なので、この見積もりには入っていない。

---

## 4. PetitOnes 参照と、TeamPuchi fork への差し替え候補

**実際の書き換えは本 PR では行わない**（段0 の PR と衝突するため）。候補の一覧化のみ。

リポジトリ全体の `PetitOnes` / `petitones` 出現は **34箇所**。
うち **挙動を変えるのは 3箇所だけ**で、残り 31箇所はドキュメント内のリンク・説明文。

### 4.1 挙動を変える参照（3箇所）

| # | 箇所 | 現在の値 | 影響 |
|---|---|---|---|
| P1 | `scripts/sync-repos.sh:7` | `ORG_URL_BASE="https://github.com/PetitOnes"` | 5〜7リポジトリの clone 元 |
| P2 | `scripts/sync-repos.ps1:7` | `$OrgUrlBase = "https://github.com/PetitOnes"` | 同上（Windows 版。クラウド版では不要になる見込み） |
| P3 | `docker-compose.release.yml:6` | `image: ghcr.io/petitones/m5-petit-core:latest` | release 用イメージ（`docker-compose.release.yml:3` の自認どおり**未公開**） |

### 4.2 差し替え候補一覧

`list_repos` で TeamPuchi org の実在リポジトリを確認した結果:

| `sync-repos.sh` が引く名前 | 行 | TeamPuchi 側の fork | 状態 | 差し替え可否 |
|---|---|---|---|---|
| `m5-petit-mcp` | `sync-repos.sh:39` | **無し** | — | **不可**（先に fork が要る） |
| `m5-petit-app` | `sync-repos.sh:40` | `TeamPuchi/m5-petit-app` | **private**・2026-09-22 push | 名前は一致。ただし §4.3 の認証問題あり |
| `m5-petit-memory` | `sync-repos.sh:41` | `TeamPuchi/petit-memory` | **public** fork・2026-07-08 push | 可。ただし §4.3 の**名前ズレ**あり |
| `m5-petit-desire` | `sync-repos.sh:42` | **無し** | — | **不可**（先に fork が要る） |
| `m5-petit-scripts` | `sync-repos.sh:43` | **無し** | — | **不可**（先に fork が要る） |
| `m5-petit-speech` | `sync-repos.sh:47` | **無し** | 任意（`WITH_SPEECH=1` 時のみ） | 不可 |
| `m5-petit-voice-recognition` | `sync-repos.sh:48` | **無し** | 任意 | 不可 |

参考: TeamPuchi org には他に `akatsuki-petit` / `petit-infra` / `petit-app` / `petit-sns` /
`m5-petit-firmware` / `petit-ui` があるが、`sync-repos.sh` が引く 5コンポーネントとの対応は
名前からは判断できないため **未確認**。

### 4.3 単純な org 置換では済まない 2点

**(a) fork のリポジトリ名が揃っていない。**
TeamPuchi 側は `petit-env` / `petit-memory` と **`m5-` プレフィックスを落としている**一方、
`m5-petit-app` は残している。`sync-repos.sh:18-31` の `sync_repo()` は
**リポジトリ名をそのままローカルディレクトリ名に使う**（`local path="$REPOS_DIR/$name"`, 21行目）。
ローカルのディレクトリ名は以下から参照されており、変えると**全部壊れる**:

- `docker-compose.yml:23-27`（マウント先パス）
- `sample-character/config/autonomous-mcp.json:5,13,20`（`uv run --directory` のパス）
- `scripts/run-for-each-character.sh:35,37,45,47`
- `scripts/autonomous-action.sh:229`
- `scripts/entrypoint.sh:24`

→ **`sync_repo()` に「リポジトリ名」と「配置先ディレクトリ名」を分けて渡せるようにする**のが最小の直し方。
（例: `sync_repo <配置先ディレクトリ名> <リポジトリ名> <ブランチ>`）

**(b) private リポジトリは匿名 clone できない。**
`TeamPuchi/m5-petit-app` は private。`sync-repos.sh:30` は `git clone` を素で叩くだけなので、
**EC2 上では認証（deploy key / PAT / GitHub App）が要る**。クラウド版 v0 の秘密管理として設計が要る項目。

### 4.4 ドキュメント側の参照（31箇所・挙動に影響なし）

`README.md` 12・`README_en.md` 12・`scripts/autonomous-action.sh` 2（コメント）・
`docker-compose.release.yml` 2（1つは P3、もう1つはコメント）・
`scripts/sync-repos.sh` 2（1つは P1、もう1つはコメント）・`scripts/sync-repos.ps1` 2（同様）・
`scripts/experience-watchdog.sh` 1（コメント）・`release/README-for-users.md` 1。

上流へのアトリビューションとして**残すべきものと、TeamPuchi に向けるべきものが混在**している。
fork である以上、上流リンクを全部消すのは適切でない。差し替え PR ではここを一律置換しないこと。

---

## 5. 実行時に要るもの（名前と用途のみ。値は書かない）

### 5.1 環境変数

| 名前 | 出典 | 用途 | 秘密 |
|---|---|---|---|
| `TZ` | `docker-compose.yml:15`, `.env.example:5` | cron の時刻解釈（`cron/petit.cron:19` の 4:05 が依存） | — |
| `CHARACTER_IDS` | `docker-compose.yml:17`, `run-for-each-character.sh:20` | 実行対象キャラのカンマ区切り一覧 | — |
| `PETIT_DATA_DIR` | `Dockerfile.core:21`, `docker-compose.yml:16` | キャラデータ・ログの root | — |
| `DASHBOARD_PORT` | `docker-compose.yml:19`, `.env.example:12` | ホスト側の公開ポート | — |
| `M5_HOSTS_<ID大文字>` | `.env.example:17-19` | 各キャラの M5 デバイスの IP | — |
| `ANTHROPIC_API_KEY` | `.env.example:26`（既定はコメントアウト） | API キー課金時のみ。既定は `claude login` のサブスク認証 | **秘密** |
| `SPEECH_API_URL` | `.env.example:32` | 外部 TTS サーバー。任意 | — |
| `ASR_API_URL` | `.env.example:33` | 外部 ASR サーバー。任意 | — |
| `M5_PETIT_*_BRANCH` ×5 | `.env.example:36-40` | `sync-repos.sh` が引くブランチ | — |
| `WITH_SPEECH` | `.env.example:43` | 音声コンポーネントを取得するか | — |
| `M5_PETIT_SPEECH_BRANCH` / `M5_PETIT_VOICE_RECOGNITION_BRANCH` | `.env.example:44-45` | 同上 | — |
| `CLAUDE_MODEL` | `autonomous-action.sh:202` | 自律行動で使うモデル（既定 `sonnet`） | — |
| `MAX_TURNS` | `autonomous-action.sh:36` | 上書き用。既定は `settings.json` の `max_turns` | — |
| `LOG_RETENTION_DAYS` | `autonomous-action.sh:56` | ログ保持日数（既定 7） | — |
| `PETIT_USER_NAME` / `PETIT_USER_ROOM` | `autonomous-action.sh:51-52` | プロンプト内の呼称 | — |
| `EXPERIENCE_DAEMON_DIR` | `experience-watchdog.sh:18` | 体験デーモンの場所。Phase 1 では未使用 | — |
| `MEMORY_DB_PATH` | `run-for-each-character.sh:48`, `autonomous-mcp.json:15` | キャラごとの記憶 DB パス | — |
| `MEMORY_EMBEDDING_MODEL` | `petit-memory/.env.example:10` | 埋め込みモデル名の上書き | — |

**クラウド版で追加が要る見込み**［推測］: private リポジトリ clone 用の認証（§4.3 b）、
HuggingFace キャッシュ先の指定（§3.4）。

### 5.2 秘密（値は書かない）

| 秘密 | 置き場所 | 備考 |
|---|---|---|
| claude CLI の認証情報 | `/home/petit/.claude`（`Dockerfile.core:70`, `docker-compose.yml:22`） | `.env.example:23` のとおり `docker compose run --rm core claude login` を **一度だけ手動実行**して作る。1家1コンテナだと**家ごとに手動ログインが要る**のが v0 の運用上の詰まりどころ |
| `ANTHROPIC_API_KEY` | `.env`（`.env.example:26`） | API 課金にする場合のみ |
| GitHub 認証 | 未設計 | `TeamPuchi/m5-petit-app` が private のため必要（§4.3 b） |

`.env` は `.gitignore:6` で除外済み。**ただし `.dockerignore` が無いので build context には入る**（B4）。

### 5.3 マウント

| コンテナ内パス | 種別 | 出典 | 用途 |
|---|---|---|---|
| `/data` | 名前付きボリューム `petit-data` | `docker-compose.yml:21` | キャラデータ・記憶 DB・ログ。**永続必須** |
| `/home/petit/.claude` | 名前付きボリューム `petit-claude-auth` | `docker-compose.yml:22` | claude 認証。**永続必須** |
| `/opt/petit/repos/m5-petit-{mcp,app,memory,desire,scripts}` | バインド `:ro` | `docker-compose.yml:23-27` | コンポーネント本体。**C1 の問題あり** |
| `/opt/petit/sample-character` | バインド `:ro` | `docker-compose.yml:28` | キャラ雛形 |
| （未設定）HuggingFace キャッシュ | — | — | **§3.4 のとおり永続化されていない。要追加** |

### 5.4 ポート

| ポート | 出典 | 用途 |
|---|---|---|
| コンテナ 8765 | `Dockerfile.core:75`, `docker-compose.yml:19` | ダッシュボード（FastAPI, `entrypoint.sh:27`） |
| ホスト `${DASHBOARD_PORT:-8765}` | `docker-compose.yml:19` | 上記の公開先 |

外向きに必要な通信［推測］: Anthropic API、HuggingFace（初回モデル取得）、GitHub（`sync-repos.sh`）、
npm / PyPI / NodeSource（build 時）。LAN 側は M5 デバイスへの到達が要る（`.env.example:15-18`）
——**EC2 に置くと、家庭内 LAN の M5 に直接届かない**。v0 の構成上いちばん大きな未解決点だが、本監査の範囲外。

### 5.5 cron の時刻（`cron/petit.cron`）

| 行 | スケジュール | ジョブ | ログ |
|---|---|---|---|
| 13 | `*/20 * * * *` | `autonomous`（自律行動） | `/data/logs/autonomous-cron.log` |
| 16 | `*/5 * * * *` | `desire`（欲求更新） | `/data/logs/desire-cron.log` |
| 19 | `5 4 * * *` | `memory-sleep`（記憶整理） | `/data/logs/memory-sleep-cron.log` |
| 24 | `*/5 * * * *` | `experience-watchdog` | `/data/logs/experience-watchdog-cron.log` |

すべて `TZ` に依存（`cron/petit.cron:18` が自認）。`@reboot` 相当は supercronic ではなく
`entrypoint.sh` 側で処理（`cron/petit.cron:9-10`, `entrypoint.sh:15-45`）。

**1家1コンテナでの含意**: 自律行動は 20分ごとだが `autonomous-action.sh:122-177` の
スケジュール制御で非アクティブ時間帯はほぼ握り潰される（`sample-character/config/settings.json:7-11` の
既定は 7-8時 / 12-13時 / 18-24時）。一方 **`desire` と `experience-watchdog` は 5分ごとに無条件で走る**ので、
家数ぶんの常時負荷はここが効く。t4g のサイジングはこの 2本を基準にすべき。

---

## 6. 次にやること

優先順:

1. **EC2（t4g）で実 build を 1回**。このセッションでは docker が無く未実行のまま。
   確かめたいのは (a) **`docker run --rm <image> supercronic -version` が通るか**（A1。build 成功では判定できない）、
   (b) B1 の Node 20 で `npm install -g` が警告で済むか失敗するか、さらに `claude --version` が Node 20 で通るか、
   (c) arm64 で `nvidia-*` が解決対象外になるか、(d) 実イメージサイズ、(e) 所要時間。
   **合格条件は「build が通ること」ではなく「コンテナを起動して supercronic と claude が動くこと」**。
   費用は t4g.small を build の間だけ立てれば数十円で済む見込み［推測］。
2. **修正 PR その1（A1 + B1 + B2 + B3 + B4）**。アーキ分岐・Node 22・バージョン固定・`.dockerignore`。
   arm64 の sha256 は §A1 の表の値をそのまま使える。**1 と 2 は順序を入れ替えてもよい**
   （修正を当ててから 1回だけ build するほうが安い）。
3. **C1（`:ro` × `uv run`）の設計判断をなぎに上げる**。
   コード修正ではなく方針決め。クラウド版 v0 では「コンポーネントをイメージに焼き込む」方向が素直に見えるが、
   dev の差し替えやすさとのトレードオフがあるので勝手に決めない。
4. **PetitOnes → TeamPuchi の差し替え PR**（§4）。ただし前提として
   `m5-petit-mcp` / `m5-petit-desire` / `m5-petit-scripts` の fork が要る（現状 TeamPuchi に無い）。
   段0 の PR と衝突するため、本監査では手を付けていない。
5. **HuggingFace キャッシュの永続化**（§3.4）。コンテナ作り直しのたびに 1GB 級を再取得するのは
   1家1コンテナ運用では効いてくる。

本監査で**やらなかったこと**: コード修正、PetitOnes org への一切のアクセス書き込み、EC2 の起動、秘密の値の記載。
