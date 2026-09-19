# conahcnuj

GitHub App として git 操作・認証を行うための、Git + opencode 設定をまとめたリポジトリ。

GitHub App「conahcnuj」のインストールトークンを発行し、それを利用して:

- `gh` CLI / GitHub API が **App 名義（`conahcnuj[bot]`）** で動く
- opencode 内の git 操作が **App 名義** で行われる
  - `git commit` の `user.name` / `user.email`
  - `git push` 等の認証（credential helper）

## 構成

```
.
├── gh-app/                    # シェルスクリプト群（App トークン発行・認証まわり）
│   ├── get-token.sh           #   JWT 署名 → インストールトークン取得（キャッシュ付き）
│   ├── git-credential-helper.sh  # git 用 credential helper
│   ├── setup-git.sh           #   リポジトリに bot 向け git config を適用
│   ├── app.env                #   実設定（gitignore 対象・リポジトリ管理外）
│   └── app.env.example        #   設定テンプレート
├── plugins/gh-app-token.ts    # opencode プラグイン（GH_TOKEN / GIT_CONFIG_* を注入）
├── install.ps1                # グローバル設定（~/.config/opencode）へ配置
├── .github/workflows/ci.yml   # GitHub Actions (Windows)
├── .gitignore
└── AGENTS.md
```

## 仕組み

1. `get-token.sh` が GitHub App の秘密鍵で JWT を署名し、
   `POST /app/installations/{id}/access_tokens` でインストールトークン（1時間有効）を取得。
   取得済みなら有効期限内はキャッシュ（`gh-app/token.cache`）を返す。
2. opencode プラグイン `plugins/gh-app-token.ts` が `shell.env` フックで
   `GH_TOKEN` と `GIT_CONFIG_*`（user.name / user.email / credential.helper / commit.gpgsign）を注入。

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
INSTALLATION_ID=<your-installation-id>
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=${HOME}/.ssh/conahcnuj.private-key.pem
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
```

秘密鍵（`.pem`）は**このリポジトリに絶対にコミットしない**こと。`app.env` も `.gitignore` 済み。

### 2. グローバル設定へ配置

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
# 任意の場所へ:  -Destination C:\path\to\dir
```

`~/.config/opencode/gh-app/` と `~/.config/opencode/plugins/` へ展開され、
`plugins/*.ts` は opencode が自動ロードする。

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
- **CI が secret で e2e をスキップする**
  `e2e` ジョブは `APP_ID` / `INSTALLATION_ID` / `PRIVATE_KEY` が無いとスキップされる。

## CI

GitHub Actions（`.github/workflows/ci.yml`、全ジョブ `windows-latest`）:

| ジョブ         | 内容                                     |
| -------------- | ---------------------------------------- |
| `lint-bash`    | `bash -n` + shellcheck                   |
| `lint-ps`      | `install.ps1` の構文チェック             |
| `install-test` | `install.ps1` を一時ディレクトリへ展開検証 |
| `e2e`          | 実トークン発行 + App 名義認証 + `ls-remote`（secret があれば） |

e2e 用のリポジトリ設定 → Actions → Secrets に登録する変数:

- `APP_ID` — GitHub App の App ID
- `INSTALLATION_ID` — App のインストール ID
- `APP_SLUG` — App のスラッグ（例: `conahcnuj`）
- `PRIVATE_KEY` — App の秘密鍵（PEM 全文）
- `TEST_REPO` — 認証テストに使うリポジトリ（例: `nahcnuj/makamujo`）