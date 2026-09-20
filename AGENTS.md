# AGENTS.md

リポジトリ内でコード変更や調査を行う AI エージェント向けのルール。

## このリポジトリの目的

GitHub App「conahcnuj」のインストールトークンを発行し、`gh` CLI と opencode 内の git 操作を App 名義で行えるようにする。スクリプト・プラグイン・CI・配置スクリプトを管理する。

## 基本ルール

- 設定値（APP_ID / BOT_USER_ID / INSTALLATION_ID / APP_SLUG / PRIVATE_KEY_PATH / BASH_EXE）は**ハードコードしない**。必ず `gh-app/app.env`（または `app.env.example`）から読み取る。`BOT_USER_ID` は bot アカウント（`<slug>[bot]`）のユーザー ID。
- 秘密鍵（`.pem`）をリポジトリへコミットしない。`app.env` は `.gitignore` 済み。
- 変数展開はシェルスクリプト内で常にブレース付き `${var}` を使う。`$var` は使わない。
- Windows で `bash` の素コマンドは WSL（`C:\Windows\System32\bash.exe`）に解決されることがある。スクリプト・プラグインで bash を起動するときは必ず `BASH_EXE`（`C:/Program Files/Git/bin/bash.exe`）を使う。
- 作業後に opencode を再起動しないとプラグイン変更は反映されない（プラグインは起動時ロード）。

## ファイルガイド

| パス | 役割 | 注意 |
| ---- | ---- | ---- |
| `gh-app/get-token.sh` | JWT署名 → インストールトークン取得（`token.cache` キャッシュ付き） | `app.env` → 無ければ `app.env.example` を fallback |
| `gh-app/git-credential-helper.sh` | git credential helper（stdin を読み捨て stdout に username/password 出力） | |
| `gh-app/setup-git.sh` | リポジトリへ bot 向け git config を適用 | 設定は `app.env` から取得 |
| `gh-app/api-commit.sh` | GraphQL（`createCommitOnBranch`）で Verified コミットをブランチに作成。`--all` で作業ツリー全体を一括コミット、owner/repo/branch は自動検出 | `curl`/`openssl`/`sed` が必要。Ubuntu / Windows（Git Bash）で動作 |
| `gh-app/mock-test.sh` | offline モックテスト（キャッシュ / credential helper） | 秘密鍵・ネットワーク不要。CI の `mock-test` と同じ検証 |
| `gh-app/app.env.example` | 設定テンプレート | プレースホルダ値のままにしてコミットする |
| `plugins/gh-app-token.ts` | opencode プラグイン。`shell.env` で `GH_TOKEN` と `GIT_CONFIG_COUNT/KEY/VALUE_*`（bot 名義 + `alias.vc`）注入、`tool.execute.before` で `git commit` をブロック | `BASH_EXE` で get-token.sh を実行。`loadAppEnv()` で app.env をパース |
| `install.ps1` | `~/.config/opencode`（または `-Destination`）へ配置 | 実 `app.env` があればそれを、無ければ example から作成 |
| `.github/workflows/ci.yml` | 読み取り専用 CI（`permissions: contents: read`） | `actions/checkout` は full-length SHA でピン留め（リポジトリの Actions ポリシー準拠）。`lint-bash` / `mock-test` は Ubuntu + Windows、`lint-ps` / `install-test` は Windows のみ |

## ローカル検証手順

```bash
# 構文チェック（Ubuntu で確認）
bash -n gh-app/*.sh
shellcheck -x gh-app/*.sh   # -x で app.env.example を追従（チェックは無効化しない）

# offline モックテスト（秘密鍵・ネットワーク不要）
bash gh-app/mock-test.sh

# トークン取得の確認（実キーが app.env にある前提）
bash gh-app/get-token.sh

# 設定反映の確認
bash gh-app/setup-git.sh
git ls-remote https://github.com/<owner>/<repo>.git HEAD

# Verified コミット作成の確認（実キーとアクセス権がある前提）
bash gh-app/api-commit.sh <owner>/<repo> <branch> -m "message" --file file=@file
bash gh-app/api-commit.sh -m "message" --all --dry-run   # owner/repo/branch 自動検出・API を呼ばず収集結果のみ表示
```

## 変更時の注意

- `install.ps1` や `plugins/` を変更したら、実機のグローバル設定（`~/.config/opencode/`）にも反映が必要：
  ```powershell
  powershell -ExecutionPolicy Bypass -File install.ps1
  ```
  その後 opencode を再起動。CI（`install-test` / `lint-ps`）にも同じ検証がある。
- secrets を使う実機検証（`get-token.sh` / `api-commit.sh`）は CI で行わず、ローカルで確認する。

## コミット運用

- コミット・push はユーザーが明示的に指示したときだけ行う。
- GitHub App の秘密鍵や `app.env`、`token.cache` をステージしない。
- **`git commit` は使わない**（プラグインが `commit.gpgsign=false` を注入するため unsigned になり、「Commits must have verified signatures」でブロックされる。opencode 上ではプラグインの `tool.execute.before` が `git commit` を検知してエラーにする）。代わりに Verified コミットを作成する：
  ```bash
  git vc -m "message" --all        # どのリポジトリでも動く（owner/repo/branch 自動検出）。プラグインが注入する git alias
  # または
  bash gh-app/api-commit.sh -m "message" --all   # このリポジトリ内
  ```
  新規ブランチは `--create-branch` を付ける（デフォルトブランチ起点で ref を作成し、unsigned コミットを介さない）。削除のみの変更は `--delete <path>` を使う。
- `git push` で unsigned コミットを送らない。`api-commit.sh` はコミットを直接リモートブランチに作成するため push 不要。ローカル同期は `git fetch origin` → `git reset --hard origin/<branch>`。