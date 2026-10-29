# conahcnuj

**GitHub App 名義**で Git 操作を行う GitHub Actions です。issue から PR を
作成し、レビュー対応まで行います。

> GitHub Marketplace: <https://github.com/marketplace/actions/conahcnuj>


## Getting started

### 前提条件

1. あなたのアカウントに GitHub App を作成し、対象リポジトリにインストールする。
2. 対象リポジトリの Secrets に `APP_ID` / `INSTALLATION_ID` / `PRIVATE_KEY`
   を登録する（`APP_SLUG` は Secret にしない）。
3. auto-merge を使う場合は Settings → General → Pull Requests で
   **Allow auto-merge** を有効にする。

### 使い方

1. issue を作成する。
2. ドライバがブランチ作成・Verified コミット・PR 作成・レビュー依頼まで進める。
3. PR をレビューし、Approve すると auto-merge workflow がマージする。

## Workflows

reusable workflow の呼び出し方・入力は [docs/workflows.md](docs/workflows.md) を参照。

- **issue の自動対応** (`issue-driver.yml`): issue の open/reopen などをトリガーに
  ドライバを実行し、PR 作成・レビュー依頼まで進める。
- **承認後の auto-merge** (`owner-approved-auto-merge.yml`): owner の Approve を
  受けてマージする。

## ローカルで使う (opencode)

opencode を bot 名義でローカル実行する場合の手順と配置の詳細は
[docs/installation.md](docs/installation.md) を参照。

1. `install.ps1` で配置する。
2. `~/.config/opencode/gh-app/app.env` に `APP_ID` / `INSTALLATION_ID` /
   `PRIVATE_KEY_PATH` / `APP_SLUG` / `BASH_EXE` を設定する。
3. opencode を再起動し、`gh auth status` が bot アカウント (`<slug>[bot]`) を
   示すことを確認する。
4. `conahcnuj <issue番号>` を実行するか、issue を開く。

Verified コミットやプラグインの仕組みは [docs/cli.md](docs/cli.md) と
[docs/plugin.md](docs/plugin.md) を参照。トラブルシューティングも
[docs/installation.md](docs/installation.md) を参照。

## ドキュメント

- サイト: <https://nahcnuj.github.io/conahcnuj/>
- 機械可読な索引: <https://nahcnuj.github.io/conahcnuj/llms.txt>
- AI エージェント向け: [AGENTS.md](AGENTS.md)
filePath: /home/runner/work/conahcnuj/conahcnuj/README.md