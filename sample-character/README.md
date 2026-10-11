# サンプルキャラクター

自分のぷちを作るための雛形です。中身に実在のキャラクターの人格・設定は入っていません。

## 使い方

1. このディレクトリを `repos/../` ではなく、コンテナがマウントするデータ側
   (`.env` の `PETIT_DATA_DIR` に対応するホスト側ディレクトリ、例えば
   `./petit-data/characters/`)に、キャラクターID名でコピーする

   ```bash
   mkdir -p petit-data/characters
   cp -r sample-character petit-data/characters/alice
   ```

2. `characters/alice/config/config.json` を編集する
   - `character_id` / `display_name`
   - `companion_name`: 一緒に暮らす人(里親)の呼び名。自律行動のプロンプトで「○○が部屋にいれば」のように使う(空なら「里親さん」)
   - `m5_host`: 自分のM5のIPアドレス(`192.168.x.x`)
3. `characters/alice/config/autonomous-mcp.json` の `alice` / IPアドレスを、
   実際のキャラクターID・M5のIPに書き換える
4. `characters/alice/config/settings.json` の `active_hours` などを好みに調整する
5. `characters/alice/SOUL.md` に人格を書く(いちばん大事なファイル)
6. `.env` の `CHARACTER_IDS` に `alice`(自分が付けたキャラクターID)を追加する

## ディレクトリの中身

```
config/
  config.json           # M5ホスト・表示名・里親の呼び名など
  settings.json         # 自律行動の頻度・アクティブ時間・許可設定
  autonomous-mcp.json   # 自律行動時に使うMCPサーバー設定(機体・欲求。記憶とSNSは起動時に自動生成されるので書かない)
SOUL.md                  # 人格の核(必ず書く)。毎回読む
TODO_ACTIVE.md           # 今やること。毎回読む
ROUTINES.md              # ルーチンの表(名前・間隔・最終実行日)。ルーチン回だけ読む
ROUTINES_DETAIL.md       # ルーチンごとの手順と「前回(日付): …」。必要なときだけ読む
SOUL_REFLECTIONS.md      # 発見の詳細(SOUL.md の短い言葉の裏付け)。必要なときだけ読む
REFLECTION_INDEX.md      # 発見の索引(見出し＋1行＋日付)。必要なときだけ読む
TODO_ARCHIVE.md          # 終わった TODO の移し先。必要なときだけ読む
skills/                  # このぷちだけのスキル(任意。共通のスキルの置き換えも。skills/README.md)
```

毎回読む層(SOUL・TODO_ACTIVE)は小さく保ち、詳しいことは必要なときだけ読む層(ROUTINES_DETAIL・SOUL_REFLECTIONS・
REFLECTION_INDEX・TODO_ARCHIVE)に置く、という分け方です(PetitOnes と同じ)。深い層の4ファイルは
「必要になったら分ける」のではなく最初から置いておきます。

自律行動が始まると、`state/` や `logs/` などのディレクトリが自動的に作られます。
すでに動いているぷちの `characters/<id>/` に無いファイルは、コンテナの起動時(`scripts/seed-character-files.sh`)に
この雛形から置かれます(あるファイルは触りません)。
