# conahcnuj

GitHub App として git 操作・認証を行うための、Git + opencode 設定をまとめたリポジトリ。

GitHub App「conahcnuj」のインストールトークンを発行し、それを利用して:

- `gh` CLI / GitHub API が **App 名義（`conahcnuj[bot]`）** で動く
- opencode 内の git 操作が **App 名義** で行われる
  - `git commit` の `user.name` / `user.email`（ただし `commit.gpgsign=false` のため unsigned。コミットは後述の `git vc` を使う）
  - `git push` 等の認証（credential helper）
  - `git vc` alias（Verified コミット作成）の注入
- `git commit` はプラグインの `tool.execute.before` フックでブロックし、`git vc` へ誘導する

## 構成

```
.
├── gh-app/                    # シェルスクリプト群（App トークン発行・認証まわり）
│   ├── get-token.sh           #   JWT 署名 → インストールトークン取得（キャッシュ付き）
│   ├── git-credential-helper.sh  # git 用 credential helper
│   ├── setup-git.sh           #   リポジトリに bot 向け git config を適用
│   ├── api-commit.sh          #   GraphQL（createCommitOnBranch）で Verified コミットを作成
│   ├── mock-test.sh           #   offline モックテストのランナー（秘密鍵・ネットワーク不要）
│   ├── tests/                 #   観点別テスト（get-token-cache / git-credential-helper / api-commit-args / api-commit-dryrun）
│   ├── app.env                #   実設定（gitignore 対象・リポジトリ管理外）
│   └── app.env.example        #   設定テンプレート
├── plugins/gh-app-token.ts    # opencode プラグイン（GH_TOKEN / GIT_CONFIG_* を注入）
├── install.ps1                # グローバル設定（~/.config/opencode）へ配置
├── .github/workflows/ci.yml   # GitHub Actions (Ubuntu / Windows)
├── .gitignore
└── AGENTS.md
```

## 仕組み

1. `get-token.sh` が GitHub App の秘密鍵で JWT を署名し、
   `POST /app/installations/{id}/access_tokens` でインストールトークン（1時間有効）を取得。
   取得済みなら有効期限内はキャッシュ（`gh-app/token.cache`）を返す。
2. opencode プラグイン `plugins/gh-app-token.ts` が `shell.env` フックで
   `GH_TOKEN` と `GIT_CONFIG_*`（user.name / user.email / credential.helper / commit.gpgsign）を注入。

## Verified コミットを作る（api-commit.sh）

`gh-app/api-commit.sh` は GitHub GraphQL の `createCommitOnBranch` を使い、ブランチに
**Verified 署名のついたコミット**を 1 件作成する。コミットは GitHub 側が作成するため、
「Commits must have verified signatures」等のブランチルールを満たす。

なぜ普通の `git commit` ではダメなのか: opencode 上の git は App 名義で動き、
署名鍵を持たない。`commit.gpgsign=false` なら unsigned コミットになりブロックされ、
`true` に変えても署名鍵が無いため `git commit` 自体が「gpg failed to sign」で失敗する
（bot アカウントに GPG 鍵は登録できない）。GitHub が Verified と認めるのは登録済み鍵の
署名か GitHub 自身の作成コミットだけなので、API 経由で作るしかない。

opencode 内でのコミット手順・オプション・仕様の詳細は AI エージェント向けの
`AGENTS.md`（「コミット運用」節）にある。必要な App 権限は `Contents: Read and write`
と `Workflows: Read and write`（`.github/workflows/` を変更する場合のみ）。

## インストール

前提:

- Windows + Git for Windows（`C:/Program Files/Git/bin/bash.exe`）
- opencode が `~/.config/opencode/` をグローバル設定として使う

### 1. 設定ファイルを作成

```powershell
Copy-Item gh-app\app.env.example gh-app\app.env
```

`gh-app\app.env` を編集:

```ini
APP_ID=<your-app-id>
BOT_USER_ID=<your-bot-user-id>
INSTALLATION_ID=<your-installation-id>
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=${HOME}/.ssh/conahcnuj.private-key.pem
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
```

`BOT_USER_ID` は GitHub App の bot アカウント（`conahcnuj[bot]`）のユーザー ID で、
GitHub がコミットを bot に帰属させるために使う（`APP_ID` とは別物）。
取得: `gh api users/conahcnuj%5Bbot%5D --jq '.id'`

秘密鍵（`.pem`）は**このリポジトリに絶対にコミットしない**こと。`app.env` も `.gitignore` 済み。

### 2. グローバル設定へ配置

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
# 任意の場所へ:  -Destination C:\path\to\dir
```

`~/.config/opencode/gh-app/` と `~/.config/opencode/plugins/` へ展開され、
`plugins/*.ts` は opencode が自動ロードする。`~/.config/opencode` はユーザーワイド
設定のため、このプラグイン（`GH_TOKEN` 注入・bot 名義・`git vc` alias・`git commit`
ブロック）は **opencode で開く全てのリポジトリ・全てのセッション**に適用される。
リポジトリ側での個別設定は不要。

### 3. opencode を再起動

再起動後、シェルで確認:

```bash
gh auth status
# → Logged in to github.com account conahcnuj[bot] (GH_TOKEN)
```

### 4. （任意）リポジトリ単位の git 設定

```bash
bash gh-app/setup-git.sh
```

またはプラグインが `GIT_CONFIG_*` を注入するため、opencode 上では不要。

## トラブルシューティング

- **`gh auth status` が 自分のアカウントを表示する**
  プラグインがトークンを取得できていない。`BASH_EXE` が正しい Git Bash 経路か、
  `app.env` の値を確認。Windows では素の `bash` は WSL に解決されることがあり、
  `execFileSync("bash", ...)` では Windows パスを解釈できないため必須の設定。
  変更後は opencode を再起動。
- **トークンが取れない**
  `bash gh-app/get-token.sh` を直接実行し、出力（`token.cache` 削除後に再実行）を確認。
- **CI で実トークンの検証が無い**
  CI の `mock-test` は秘密鍵・ネットワーク不要の offline 検証のみ。実トークンの
  動作確認はローカルで `bash gh-app/get-token.sh` → `bash gh-app/setup-git.sh` を
  実行して確認する。

## CI

GitHub Actions（`.github/workflows/ci.yml`）:

| ジョブ               | 内容                                          | ランナー    |
| -------------------- | --------------------------------------------- | ----------- |
| `lint-bash`          | `bash -n` + `shellcheck -x`（`gh-app/*.sh` と `gh-app/tests/*.sh`。追従・チェック無効化なし） | Ubuntu / Windows |
| `lint-ts`            | プラグインの型チェック（`tsc -p plugins`。offline stub 型のみで npm install 不要） | Ubuntu |
| `lint-ps`            | `install.ps1` の構文チェック                  | Windows     |
| `install-test`       | `install.ps1` を一時ディレクトリへ展開検証    | Windows     |
| `mock-test`          | `gh-app/mock-test.sh` 全 suite（秘密鍵・ネットワーク不要） | Ubuntu / Windows |

workflow は読み取り専用なため、`permissions: contents: read` を明示している。

秘密鍵やトークンを使う実機検証（e2e）は CI では行わない。ローカルで検証する場合
は自分のリポジトリで:

```bash
bash gh-app/get-token.sh        # 実トークン取得を確認
bash gh-app/setup-git.sh        # App 名義の git config を適用
git ls-remote https://github.com/<owner>/<repo>.git HEAD
```