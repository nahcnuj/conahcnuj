# conahcnuj

GitHub App として git 操作・認証を行うための、Git + opencode 設定をまとめたリポジトリ。

GitHub App「conahcnuj」のインストールトークンを発行し、それを利用して:

- `gh` CLI / GitHub API が **App 名義（`conahcnuj[bot]`）** で動く
- opencode 内の git 操作が **App 名義** で行われる
  - `user.name` / `user.email` による帰属付け
  - `git push` 等の認証（credential helper）

## 構成

```
.
├── gh-app/                    # シェルスクリプト群（App トークン発行・認証まわり）
│   ├── get-token.sh           #   JWT 署名 → インストールトークン取得（キャッシュ付き）
│   ├── git-credential-helper.sh  # git 用 credential helper
│   ├── setup-git.sh           #   リポジトリに bot 向け git config を適用
│   ├── api-commit.sh          #   GraphQL（createCommitOnBranch）で Verified コミットを作成
│   ├── tests/                 #   offline モックテスト（run.sh がランナー。秘密鍵・ネットワーク不要）
│   ├── app.env                #   実設定（gitignore 対象・リポジトリ管理外）
│   └── app.env.example        #   設定テンプレート
├── plugins/gh-app-token.ts    # opencode プラグイン（GH_TOKEN / GIT_CONFIG_* を注入）
├── test/                      # プラグインの smoke テスト（opencode の自動ロード対象外）
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
`true` に変えても鍵が無いため `git commit` 自体が失敗する。
bot アカウントに GPG 鍵は登録できないため、Verified にするには API 経由で
GitHub 自身にコミットを作成させるしかない。

opencode 内でのコミット手順・オプション・仕様の詳細は AI エージェント向けの
`AGENTS.md`（「コミット運用」節）にある。

## インストール

前提:

- Windows + Git for Windows（`C:/Program Files/Git/bin/bash.exe`）
- opencode が `~/.config/opencode/` をグローバル設定として使う

### 1. インストール

```sh
git clone <repo>.git
cd <repo>
./install.ps1
```

`~/.config/opencode/`（ユーザーワイド）へ展開されるため、全てのリポジトリ・セッションに適用される。

### 2. opencode を再起動

`gh-app/app.env` に実値を入れてから再起動。再起動後、opencode のシェルで確認
（自分のシェルが未ログインのままなのは正常。プラグインは opencode 内でのみ効く）:

```bash
gh auth status
# → Logged in to github.com account conahcnuj[bot] (GH_TOKEN)
```

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

CI の内容は `.github/workflows/ci.yml` を参照（AGENTS.md にジョブ一覧あり）。