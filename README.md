# conahcnuj

## Getting started

1. あなたのアカウントに GitHub App を作成する。
2. 使いたいリポジトリに作成したアプリをインストールする。
3. 対象リポジトリの Secrets に `APP_ID` / `INSTALLATION_ID` / `PRIVATE_KEY`
   を登録する（`APP_SLUG` は Secret にしない）。
4. auto-merge を使う場合は Settings → General → Pull Requests で
   **Allow auto-merge** を有効にする。

### 使い方

1. issue を作成する。
2. 作成された PR をレビューする。

## Workflows

reusable workflow の呼び出し方・入力は [docs/workflows.md](docs/workflows.md) を参照。

- **issue の自動対応** (`issue-driver.yml`): issue の open/reopen などをトリガーに
  ドライバを実行し、PR 作成・レビュー依頼まで進める。
- **承認後の auto-merge** (`owner-approved-auto-merge.yml`): owner の Approve を
  受けてマージする。

## ローカルで使う (opencode)

opencode を bot 名義でローカル実行する場合の手順です。配置の詳細は
[docs/installation.md](docs/installation.md) を参照。

前提: ネイティブ実行は Windows + Git for Windows（`C:/Program Files/Git/bin/bash.exe`）
が主対象です。pwsh があれば Linux / macOS でも配置できますが、CI 検証は
Windows のみです。配置せずに `bash bin/conahcnuj.sh` / `bash gh-app/*.sh` を直接
呼ぶだけなら bash・git・curl・openssl で足ります。

1. clone して `install.ps1` を実行する。

   ```sh
   git clone <repo>.git
   cd <repo>
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```

2. `~/.config/opencode/gh-app/app.env` に `APP_ID` / `INSTALLATION_ID` /
   `PRIVATE_KEY_PATH` / `APP_SLUG` / `BASH_EXE` を設定する。
3. opencode を再起動し、`gh auth status` が bot アカウント (`<slug>[bot]`) を
   示すことを確認する。
4. `conahcnuj <issue番号>` を実行するか、issue を開く。

opencode プラグインの仕組みは [docs/plugin.md](docs/plugin.md) を参照。

## 仕組み

1. `gh-app/get-token.sh` が GitHub App の秘密鍵で JWT を署名し、インストール
   トークン（1 時間有効）を取得する。有効期限内はキャッシュ
   (`gh-app/token.cache`) を返す。
2. opencode プラグイン `plugins/gh-app-token.ts` が `shell.env` フックで
   `GH_TOKEN` と `GIT_CONFIG_*`（bot 名義 + `alias.vc`）を注入する。
3. `experimental.chat.system.transform` フックで「コミットは `git vc`」「`gh` は
   `GH_TOKEN` で認証済みなので自分で export しない」という規則を常時注入し、
   `tool.execute.before` で `git commit` / `api-commit.sh` の直接実行を検知して
   `git vc` へ誘導する。

## Verified コミット (`git vc`)

コーディングエージェントは `git vc` でコミットします。プラグインが注入する
git alias で、GitHub GraphQL の `createCommitOnBranch` を使い Verified 署名付き
コミットをブランチに作成します。

```sh
git vc -m "message"        # staged の内容をコミット
git vc -m "message" -a     # tracked の作業ツリー変更をコミット
```

詳細は [docs/cli.md](docs/cli.md)。

## 隔離環境 (Docker)

自律実行をホストから隔離したい場合はイメージ内でドライバを動かせます。

```sh
cd <対象リポジトリ>
bash <このリポジトリ>/docker-run.sh <issue-or-PR番号>
```

対象リポジトリは `/work` にバインドマウントされ、秘密鍵と `app.env` は
イメージに焼き込まず実行時に読み取り専用でマウントします。詳細は
[docs/installation.md](docs/installation.md)。

## トラブルシューティング

- **`gh auth status` が自分のアカウントを表示する**: プラグインがトークンを
  取得できていない。`BASH_EXE` が正しい Git Bash 経路か、`app.env` の値を確認し、
  opencode を再起動する。
- **トークンが取れない**: `bash gh-app/get-token.sh` を直接実行して出力を確認する
  (`token.cache` 削除後に再実行)。
- **CI で実トークンの検証が無い**: `mock-test` は秘密鍵・ネットワーク不要の
  offline 検証のみ。実トークンの動作確認はローカルで行う。

## ドキュメント

- サイト: <https://nahcnuj.github.io/conahcnuj/>
- 機械可読な索引: <https://nahcnuj.github.io/conahcnuj/llms.txt>
- AI エージェント向け: [AGENTS.md](AGENTS.md)

## リポジトリ構成

```
.
├── gh-app/                    # シェルスクリプト群（App トークン発行・認証まわり）
├── bin/conahcnuj.sh           # issue駆動自律開発ドライバ本体
├── lib/                       # ドライバ用ライブラリ
├── plugins/gh-app-token.ts    # opencode プラグイン
├── opencode/AGENTS.md         # opencode グローバルルール
├── plugin-tests/              # プラグインのテスト
├── driver-tests/              # ドライバの offline モックテスト
├── Dockerfile / docker-run.sh # 隔離実行
├── install.ps1                # 配置スクリプト
├── docs/                      # リファレンス（GitHub Pages で配信）
├── .github/workflows/         # GitHub Actions
├── .gitignore
└── AGENTS.md                  # AI エージェント向けルール
```
