# conahcnuj ドキュメント

GitHub App「conahcnuj」の設定・CLI・ドライバ・プラグイン・GitHub Actions をまとめた
リファレンスです。コーディングエージェントが**一次資料**として参照することを想定し、
ホスト上にアプリをインストール済みであることやリポジトリの存在を前提にしない記述で
書いています。

- 配信先: <https://nahcnuj.github.io/conahcnuj/>（GitHub Pages。**常に最新版のみ**で、
  バージョン切り替えはありません）
- 各ページは HTML と Markdown 原文（同じパスの `.md`）の両方が開けます。
- 機械可読な索引は [llms.txt](llms.txt) にあります。
- このドキュメント自体はリポジトリの `docs/` ディレクトリがソースで、
  Pages ワークフローが自動生成して配信します（[workflows.md](workflows.md)）。

## conahcnuj とは

git 操作・GitHub API を **GitHub App の名義**（`<slug>[bot]`）で行うための
設定とスクリプトの集めに加え、issue を PR まで自律的に運ぶドライバを含みます。

- App のインストールトークンを発行し、`gh` CLI / git / opencode 内の作業が
  bot 名義で動く
- issue 駆動自律開発ドライバ `conahcnuj`（実装 → Verified コミット → PR →
  owner レビュー依頼まで自動。マージはしない）

## 目次

| ページ | 内容 |
| --- | --- |
| [configuration.md](configuration.md) | `gh-app/app.env` のキー・キャッシュファイル・API ベース URL |
| [cli.md](cli.md) | `gh-app/` の CLI（トークン発行・credential helper・Verified コミットなど） |
| [driver.md](driver.md) | ドライバ `conahcnuj` の使い方・フロー・エージェント契約（`.commit-msg` など） |
| [plugin.md](plugin.md) | opencode プラグインのフックと注入する環境変数、`git vc` |
| [environment.md](environment.md) | 環境変数の一覧（ドライバ・Docker・テスト用を含む） |
| [workflows.md](workflows.md) | GitHub Actions（CI・自動ドライバ・auto-merge・Pages）と必須チェック |
| [self-improvement.md](self-improvement.md) | 週次の auto-drive ログ解析（自己研鑽のループ） |
| [installation.md](installation.md) | `install.ps1`・Docker による配置と実行 |
| [llms.txt](llms.txt) | 上記全ページの索引（機械可読） |

## このドキュメントの読み方

- 仕様（入出力・終了コード・既定値）はこのページ群が唯一の基準です。ソースの
  読み合わせは裏取りとしてだけ行ってください。
- 各 CLI の終了コードは常に `0` = 成功、`1` 以上 = エラー（詳細は stderr）です。
- 秘密情報（`app.env`・秘密鍵・キャッシュ）はリポジトリにコミットしません。
  設定の置き方は [configuration.md](configuration.md) を参照してください。
