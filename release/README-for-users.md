# petit-env 利用者向けガイド

Docker Desktopがあれば、開発環境を作らずに自分のぷち(M5 Petit)を動かせます。

## 必要なもの

- Docker Desktop (Windows / macOS)
- 自分のClaudeアカウント(サブスクリプション or APIキー)
- M5Stack CoreS3(ぷち本体)とそのIPアドレス

## 起動方法

1. このディレクトリを含むリリースzipを展開する
2. `.env.example` を `.env` にコピーし、`CHARACTER_IDS` と `M5_HOSTS_<ID>` を編集する
3. Windowsは `start-windows.bat`、macOSは `start-macos.command` をダブルクリック
4. 初回のみ、ターミナルで以下を実行してClaude認証する:
   ```
   docker compose -f docker-compose.release.yml exec core claude login
   ```
5. ブラウザで `http://localhost:8765` を開く(ダッシュボード)

## 終了方法

```
docker compose -f docker-compose.release.yml down
```

## キャラクターを作る

`sample-character/` をコピーして `characters/<id>/` を作り、`SOUL.md` に人格を書く。
詳しくは `sample-character/README.md` を参照。

## 注意(Phase 1)

このリリース手順は **未検証(build-untested)** です。`ghcr.io/teampuchi/petit-core`
イメージはまだ公開されていません。まずは開発者向けの `docker-compose.yml`(dev)から
動作確認する予定です。
