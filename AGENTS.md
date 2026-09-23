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
| `gh-app/api-commit.sh` | GraphQL（`createCommitOnBranch`）で Verified コミットをブランチに作成。無印は staged、`-a` は tracked 変更をコミット、owner/repo/branch は自動検出 | `curl`/`openssl`/`sed` が必要。Ubuntu / Windows（Git Bash）で動作 |
| `gh-app/bot-user-id.sh` | bot アカウントの user ID を出力（app.env 優先、無ければ公開 API から自動解決） | ネットワーク不要なのは app.env 設定済みの場合のみ |
| `gh-app/tests/run.sh` | offline モックテストのランナー（同ディレクトリの観点別テストを順に実行） | 秘密鍵・ネットワーク不要。CI の `mock-test` はこのファイルを実行する |
| `gh-app/app.env.example` | 設定テンプレート | プレースホルダ値のままにしてコミットする。`BOT_USER_ID` は書かない（公開 API から自動解決。手動上書き時のみ追加） |
| `gh-app/tests/` | 観点別テスト（`get-token-cache` / `git-credential-helper` / `api-commit-args` / `api-commit-dryrun` / `bot-user-id`） | いずれも秘密鍵・ネットワーク不要。`run.sh` から実行 |
| `plugins/gh-app-token.ts` | opencode プラグイン。`shell.env` で `GH_TOKEN` と `GIT_CONFIG_*`（bot 名義 + `alias.vc`。配列生成）注入、`tool.execute.before` で `git commit` をブロック | `BASH_EXE` で get-token.sh を実行。`loadAppEnv()` で app.env をパース。`BOT_USER_ID` 未設定時は `bot-user-id.sh` で自動解決 |
| `test/smoke.sh` / `smoke-run.js` | プラグインの runtime smoke テスト（`install.ps1`→読込→env 契約と commit 誘導を検証。`plugins/` 外に置くのは opencode の自動ロード対象外にするため） | node/npm と pwsh が必要。CI の `plugin-smoke` で実行 |
| `plugins/package.json`・`tsconfig.json`・`plugin-stub.d.ts` | 型チェック基盤（`@types/node` 実物＋ `@opencode-ai/plugin` 最小 stub） | CI の `lint-ts` で実行。`node_modules/` は gitignore |
| `bin/conahcnuj.sh` | issue駆動自律開発ドライバ（issue→フィーチャーブランチ→PR→レビュー対応→ready to merge まで） | `lib/`・`tests/`・`test.sh` とセット。実行は `conahcnuj <issue番号>`（PR番号なら自動で再開）。ブランチ名・コミットメッセージはコーディングエージェントが決める（`.branch-name` / `.commit-msg`）。環境変数上書き・offline テストモードはヘッダーコメント参照。異常終了時はバグ報告 issue を対象リポジトリへ自動作成（`gh_api_create_issue`） |
| `lib/` | ドライバ用ライブラリ（`gh-api.sh` / `opencode.sh` / `rate-limit.sh`） | `gh-api.sh` は `GH_API_TEST_MODE=1` で stdin からモック応答を 1 コール 1 行読み、ネットワーク I/O をしない |
| `tests/`・`test.sh` | ドライバの offline モックテスト（モック API tape ＋ モック opencode でフロー検証） | 秘密鍵・ネットワーク不要。CI の `mock-test` で `test.sh` を実行 |
| `install.ps1` | `~/.config/opencode`（または `-Destination`）へ配置。加えて `conahcnuj` バイナリ（既定 `~/.local/bin`）と bin 側 `gh-app/`・`lib/` を配置 | gh-app は**2 箇所**へ配備（opencode 設定用とドライバ用）。実 `app.env` があればそれを、無ければ example から作成 |
| `Dockerfile` | conahcnuj 実行用の隔離イメージ（opencode・git・curl・openssl とドライバを同梱） | 秘密鍵・`app.env` は焼き込まない。`ENTRYPOINT` はドライバ |
| `docker-run.sh` | 上記イメージでドライバを実行するラッパー（対象リポジトリを `/work` へマウント、コンテナ用 `app.env` を生成し秘密鍵を読み取り専用マウント） | テストではなく**実走行**用（実キー・ネットワーク・opencode 設定が必要） |
| `.github/workflows/ci.yml` | 読み取り専用 CI（`permissions: contents: read`） | `actions/checkout` は full-length SHA でピン留め（リポジトリの Actions ポリシー準拠）。`lint-bash` / `mock-test` / `plugin-smoke` は Ubuntu + Windows、`lint-ts` / `e2e-opencode` は Ubuntu、`lint-ps` / `install-test` は Windows のみ |

## ローカル検証手順

```bash
# 構文チェック（Ubuntu で確認）
bash -n gh-app/*.sh gh-app/tests/*.sh
shellcheck -x gh-app/*.sh gh-app/tests/*.sh   # -x で app.env.example を追従（チェックは無効化しない）

# プラグイン型チェック（@types/node は plugins/package.json＋lock から取得）
(cd plugins && npm ci --no-audit --no-fund && ./node_modules/.bin/tsc -p ../plugins --noEmit)

# offline モックテスト（秘密鍵・ネットワーク不要）
bash gh-app/tests/run.sh
bash test.sh   # ドライバの offline テスト（bin/・lib/・tests/）

# e2e は CI の `e2e-opencode` ジョブで実行（手順は ci.yml に直接記載）。
# ローカルで流す場合は opencode 本体・node・pwsh を用意し、ジョブの手順をなぞる
#（opencode の無料モデルを使うため秘密鍵・課金不要）

# トークン取得の確認（実キーが app.env にある前提）
bash gh-app/get-token.sh

# 設定反映の確認
bash gh-app/setup-git.sh
git ls-remote https://github.com/<owner>/<repo>.git HEAD

# Verified コミット作成の確認（実キーとアクセス権がある前提）
bash gh-app/api-commit.sh <owner>/<repo> <branch> -m "message" --delete path/to/removed
bash gh-app/api-commit.sh -m "message" -a --dry-run   # owner/repo/branch 自動検出・API を呼ばず収集結果のみ表示
```

## 変更時の注意

- `install.ps1` や `plugins/` を変更したら、実機のグローバル設定（`~/.config/opencode/`）にも反映が必要：
  ```powershell
  powershell -ExecutionPolicy Bypass -File install.ps1
  ```
  その後 opencode を再起動。CI（`install-test` / `lint-ps`）にも同じ検証がある。
  `bin/`・`lib/` を変更したら `conahcnuj` 本体（既定 `~/.local/bin/conahcnuj`）と
  bin 側 `gh-app/`・`lib/` の再配備も同じ install.ps1 で行われる。
- 再起動後は opencode 内のシェルで `gh auth status` が bot アカウントを示すことを確認する。
- secrets を使う実機検証（`get-token.sh` / `api-commit.sh`）は CI で行わず、ローカルで確認する。

## コミット運用

- コミット・push はユーザーが明示的に指示したときだけ行う。
- GitHub App の秘密鍵や `app.env`、`token.cache` をステージしない。
- **`git commit` は使わない**（プラグインが `commit.gpgsign=false` を注入するため unsigned になり、「Commits must have verified signatures」でブロックされる。`true` に変えても署名鍵が無いため `git commit` 自体が失敗する。opencode 上ではプラグインの `tool.execute.before` が `git commit` を検知してエラーにする）。代わりに Verified コミットを作成する：
  ```bash
  git vc -m "message"              # staged の内容をコミット（git commit 相当）。どのリポジトリでも動く
  git vc -m "message" -a           # tracked の作業ツリー変更をコミット（git commit -a 相当）
  # またはこのリポジトリ内では直接スクリプトでも同じ
  bash gh-app/api-commit.sh -m "message" [-a]
  ```
  `git vc` はプラグインが注入する git alias（組み込みの上書きは不可のため新規名 `vc`）。
  owner/repo/branch は `git remote` と現在ブランチから自動検出される。
- `api-commit.sh` の仕様:
  - 1 実行でブランチ先端に Verified コミットを **1 件だけ**作る（author は bot、committer は GitHub・署名付き）。`git add -A`＋`git commit -m` と収集内容は同じだが、作成場所（GitHub サーバー側）が違うため署名付きになる。
  - 無印は staged の内容を index（`git show :path`）から読む（`git commit` 相当。新規ファイルは `git add` でステージする）。`-a` は tracked の作業ツリー変更を読む（untracked 除外。`git commit -a` 相当。削除・リネーム対応）。
  - 注意: `-a` はコミット操作であり、ステージングでは無い。収集と Verified コミット作成を1実行で行う（中間ステージは作らない）。
  - `--delete <path>`（明示削除）、`--create-branch`（デフォルトブランチ起点で ref を作成。新規ブランチ用）、`--dry-run`（API を呼ばず収集結果のみ表示。token/network 不要）。
  - 既存ブランチへの追記のみ。履歴の書き換え・force-push はしない。unsigned コミットが既にあるブランチは、先に `git fetch` → `git reset --hard` で作り直してから使うこと。
- `git push` で unsigned コミットを送らない。`api-commit.sh` はコミットを直接リモートブランチに作成するため push 不要。ローカル同期は `git fetch origin` → `git reset --hard origin/<branch>`。