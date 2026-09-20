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
│   ├── mock-test.sh           #   offline モックテスト（秘密鍵・ネットワーク不要）
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

bash と `curl` / `openssl` / `sed` があれば Ubuntu でも Windows（Git Bash）でも動く。

```bash
# どのリポジトリでも同じ1行（owner/repo/branch は git remote と現在ブランチから自動検出）
git vc -m "commit message" --all      # 作業ツリーの変更（新規・変更・削除）を一括コミット

# このリポジトリ内では直接スクリプトを叩いても同じ
bash gh-app/api-commit.sh -m "commit message" --all

# ファイルを明示指定（author は conahcnuj[bot]）
bash gh-app/api-commit.sh <owner>/<repo> <branch> -m "commit message" \
  --file path/to/file=新内容 \        # インライン
  --file path/to/file=@local-file     # ローカルファイルの中身
  --delete path/to/removed            # 削除

# 新規ブランチ（デフォルトブランチ起点で ref を作成。unsigned コミットを介さない）
git vc -m "commit message" --all --create-branch

# 何がコミットされるか事前確認（API を呼ばない）
bash gh-app/api-commit.sh -m "commit message" --all --dry-run
```

`git commit` は使わないこと。プラグインが `commit.gpgsign=false` を注入するため
unsigned コミットになり、「Commits must have verified signatures」のブランチルールで
ブロックされる。opencode 上ではプラグインが `git commit` を検知してエラーにし、
`git vc` を案内する（git の alias は組み込みコマンドを上書きできないため、新規名
`vc` で提供する）。

### 仕様（api-commit.sh）

- 1 実行でブランチ先端に Verified コミットを **1 件だけ**作る。author は
  `conahcnuj[bot]`、committer は GitHub（署名付き）。
- `--all` の収集規則（`git status --porcelain -z` 基準）:
  - 追加・更新: 新規（staged/unstaged）、変更、untracked ファイル（中身は作業ツリー現物）
  - 削除: 削除されたパス（`D`）
  - リネーム: 新パスを追加・旧パスを削除として扱う
- owner/repo・branch の決定規則: 先頭の位置引数（`<owner>/<repo>` は `/` 含みで判定、
  それ以外は branch 名）→ 無ければ `git remote get-url origin` と現在ブランチから
  自動検出。
- `--create-branch` が無い状態でブランチが存在しなければエラー。
  付きの場合はデフォルトブランチ先端から ref を作成（コミット push を介さない）。
- `--dry-run` はトークン・network 不要で収集結果のみ表示（offline テスト可）。
- 既存ブランチへの追記のみ。履歴の書き換え・force-push はしない。
  unsigned コミットが既にあるブランチは、先に `git fetch` → `git reset --hard`
  で作り直してから使うこと。

必要な App 権限は `Contents: Read and write` と `Workflows: Read and write`
（`.github/workflows/` を変更する場合のみ）。

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
- **CI で実トークンの検証が無い**
  CI の `mock-test` は秘密鍵・ネットワーク不要の offline 検証のみ。実トークンの
  動作確認はローカルで `bash gh-app/get-token.sh` → `bash gh-app/setup-git.sh` を
  実行して確認する。

## CI

GitHub Actions（`.github/workflows/ci.yml`）:

| ジョブ               | 内容                                          | ランナー    |
| -------------------- | --------------------------------------------- | ----------- |
| `lint-bash`          | `bash -n` + `shellcheck -x`（追従・チェック無効化なし） | Ubuntu / Windows |
| `lint-ps`            | `install.ps1` の構文チェック                  | Windows     |
| `install-test`       | `install.ps1` を一時ディレクトリへ展開検証    | Windows     |
| `mock-test`          | モックテスト（秘密鍵・ネットワーク不要）      | Ubuntu / Windows |

workflow は読み取り専用なため、`permissions: contents: read` を明示している。

秘密鍵やトークンを使う実機検証（e2e）は CI では行わない。ローカルで検証する場合
は自分のリポジトリで:

```bash
bash gh-app/get-token.sh        # 実トークン取得を確認
bash gh-app/setup-git.sh        # App 名義の git config を適用
git ls-remote https://github.com/<owner>/<repo>.git HEAD
```