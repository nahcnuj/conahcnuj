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
| `gh-app/tests/` | 観点別テスト（`get-token-cache` / `get-token-pem-path` / `git-credential-helper` / `api-commit-args` / `api-commit-dryrun` / `api-commit-trailer` / `bot-user-id`） | いずれも秘密鍵・ネットワーク不要。`run.sh` から実行。`get-token-pem-path` は WSL `/mnt/<drive>/` → `/<drive>/` の書き換えを検証する |
| `plugins/gh-app-token.ts` | opencode プラグイン。`shell.env` で `GH_TOKEN` と `GIT_CONFIG_*`（bot 名義 + `commit.gpgsign=false` + `alias.vc`。`GIT_CONFIG_COUNT/KEY_n/VALUE_n` 形式で配列生成）注入、`tool.execute.before` で `git commit` をブロック。セッションのモデル表示名と variant を `CONAHCNUJ_COMMIT_MODEL` に入れる | **トークンは in-process で取得する**（`get-token.sh` を起動しない。RS256 署名と `token.cache` 読み出しを TS で実装。`token.cache` の形式は共有）。bot の user ID も插件内 `resolveBotUserId()` が `gh-app/bot-id.cache` 経由で解決し、`gh-app/bot-user-id.sh` は使わない。`BASH_EXE` は credential helper と `alias.vc` のコマンド文字列にのみ使う。プラグインのロード時にネットワークが要るため、`app.env` を変えたら opencode を再起動する |
| `test/smoke.sh` / `smoke-run.js` / `test/e2e-opencode.sh` | プラグインの runtime smoke テスト（`install.ps1`→読込→env 契約と commit 誘導を検証。`plugins/` 外に置くのは opencode の自動ロード対象外にするため）と、実 opencode を叩く e2e | node/npm と pwsh が必要。CI の `plugin-smoke` / `e2e-opencode` で実行 |
| `plugins/package.json`・`package-lock.json`・`tsconfig.json` | 型チェック基盤（`@types/node` 実物＋ `@opencode-ai/plugin`） | CI の `lint-ts` で実行。`node_modules/` は gitignore。`plugin-stub.d.ts` は既に廃止（実 npm パッケージに置き換え済み） |
| `bin/conahcnuj.sh` | issue駆動自律開発ドライバ（issue→フィーチャーブランチ→PR→レビュー対応→ready to merge まで） | `lib/`・`tests/`・`test.sh` とセット。実行は `conahcnuj <issue番号>`（PR番号なら自動で再開）。ブランチ名・コミットメッセージはコーディングエージェントが決める（`.branch-name` / `.commit-msg`）。環境変数上書き・offline テストモードはヘッダーコメント参照。異常終了時はバグ報告 issue を**`nahcnuj/conahcnuj` 固定**で自動作成（`gh_api_create_issue`）。作業先リポジトリが別のときもここへ出る（`owner/repo#番号` で識別） |
| `lib/` | ドライバ用ライブラリ（`gh-api.sh` / `opencode.sh` / `rate-limit.sh`） | `opencode.sh` は失敗したモデルから `sessionID` と作業ツリーを次モデルへ引き継ぐ。`gh-api.sh` は `GH_API_TEST_MODE=1` で stdin からモック応答を 1 コール 1 行読み、ネットワーク I/O をしない |
| `tests/`・`test.sh` | ドライバの offline モックテスト（モック API tape ＋ モック opencode でフロー検証） | 秘密鍵・ネットワーク不要。CI の `mock-test` で `test.sh` を実行 |
| `install.ps1` | `~/.config/opencode`（または `-Destination`）へ配置。加えて `conahcnuj` バイナリ（既定 `~/.local/bin`）と bin 側 `gh-app/`・`lib/` を配置 | gh-app は**2 箇所**へ配備（opencode 設定用とドライバ用）。実 `app.env` があればそれを、無ければ example から作成 |
| `Dockerfile` | conahcnuj 実行用の隔離イメージ（opencode・git・curl・openssl とドライバを同梱） | 秘密鍵・`app.env` は焼き込まない。`ENTRYPOINT` はドライバ |
| `docker-run.sh` | 上記イメージでドライバを実行するラッパー（対象リポジトリを `/work` へマウント、コンテナ用 `app.env` を生成し秘密鍵を読み取り専用マウント） | テストではなく**実走行**用（実キー・ネットワーク・opencode 設定が必要） |
| `.github/workflows/ci.yml` | 読み取り専用 CI（`permissions: contents: read`） | `actions/checkout` は full-length SHA でピン留め（リポジトリの Actions ポリシー準拠）。`lint-bash` / `mock-test` / `plugin-smoke` は Ubuntu + Windows、`lint-ts` は Ubuntu、`e2e-opencode` / `lint-ps` / `install-test` は Windows のみ |
| `.github/actions/install-opencode/action.yml` | opencode を最新リリースで導入する composite action（authenticated リリース検索＋PATH 設定） | `ci.yml` と `issue-driver.yml` の両方が `uses: ./.github/actions/install-opencode` で共有。未認証の `api.github.com` は共有ランナーでレート制限に当たりやすいためトークン付きで解決する |
| `.github/workflows/issue-driver.yml` | issue が open / reopen されたらドライバで自動対応を試みる（issue→PR まで。失敗時はバグ報告 issue） | タイムアウトは Actions 側で制御（`timeout-minutes: 60`）。`CONAHCNUJ_MAX_SECONDS=3540` でドライバが先に自己終了しバグ報告を残す。repo secrets `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` / `PRIVATE_KEY`（PEM）が必要。bot 名義の issue（`<slug>[bot]` 含む）は再帰防止のため `user.type` でスキップ（job レベルの `if` は `secrets` を参照できないため）。`GITHUB_TOKEN` は `contents: read` のみ（書き込みは全て App トークン）。job は **`environment: conahcnuj`** を指定しており、Environment に required reviewers を設定していると無人の実行が止まるので、GitHub 側の設定を確認する。トリガーは `issues: [opened, reopened]` に加えて `pull_request_review: [submitted, edited, dismissed]`（owner 以外の非 approve review で PR 番号を再開）と `workflow_dispatch`（入力 `number`。継続コメントの URL がこれ） |
| `.github/workflows/auto-merge.yml` | owner の PR 承認時にマージ用 workflow を呼び出す | 承認した head SHA と一致する場合だけ merge commit を要求。書き込みには `GITHUB_TOKEN` を使用。`merge-method` / `post-merge-dispatch` は転送しない（呼び出し側が直接 `owner-approved-auto-merge.yml` を使う） |
| `.github/workflows/owner-approved-auto-merge.yml` | owner 承認後のマージを `workflow_call` で再利用する workflow | 利用側は `pull_request_review` を購読し、必要な権限（`contents: write` / `pull-requests: write`、`post-merge-dispatch` を使うなら `actions: write`）を渡す。secret は不要。job 名は `enable` のまま |

## コード体系的知識（変更前に読むこと）

### データフロー

```
opencode 起動 → プラグイン gh-app-token.ts が in-process で JWT 署名
              → installation token → GH_TOKEN と GIT_CONFIG_* を shell.env へ注入
              → 以降の git / gh はすべて conahcnuj[bot] 名義
git commit   → プラグインがブロック。代わりに `git vc` = gh-app/api-commit.sh
              → GraphQL createCommitOnBranch で GitHub 側に Verified コミットを作らせる
              → 最後に `git pull origin <branch>` でローカルを同期
conahcnuj    → bin/conahcnuj.sh + lib/{gh-api,opencode,rate-limit}.sh
              → issue → ブランチ → opencode run（モデル fall-through）→ api-commit.sh
              → PR → constraints 待ち → review 待ち（APPROVED で初めて終了）
```

### 環境変数（すべて省略可）

| 変数 | 効果 |
| ---- | ---- |
| `CONAHCNUJ_REPO` | `origin` remote が無いときの `owner/repo` |
| `CONAHCNUJ_MAX_SECONDS` | 時間予算（既定 259200 = 72 h。CI は 3540） |
| `CONAHCNUJ_POLL_CONDITIONS_MIN` / `_MAX` | constraints ポーリング幅（既定 15 / 300 s） |
| `CONAHCNUJ_POLL_REVIEWS_MIN` / `_MAX` | review ポーリング幅（既定 30 / 3600 s） |
| `CONAHCNUJ_COMMIT_MODEL` | `Model:` trailer ラベル。unset なら `CONAHCNUJ_MODEL_LABEL_FILE` → `OPENCODE_LAST_MODEL` の順 |
| `CONAHCNUJ_MODEL_LABEL_FILE` | プラグインが書く表示名ファイル（`commit_changes` が読む） |
| `CONAHCNUJ_SESSION_MODEL` | プラグインがこのセッションのモデルとして記録する値 |
| `CONAHCNUJ_RUN_TIMEOUT_SECONDS` | 1 回の `opencode run` の上限（ドライバが算出） |
| `CONAHCNUJ_TEST_MODE` / `CONAHCNUJ_IMPORT` | `1` で offline テスト / `main` を実行せず source |
| `GH_APP_DIR` | `gh-app/` の場所（未設定ならスクリプト位置から解決） |
| `GH_API_TEST_MODE` | `1` で `lib/gh-api.sh` が stdin の tape を読む（ネットワーク I/O なし） |
| `GH_APP_API_BASE` | API エンドポイント（既定 `https://api.github.com`） |
| `OPENCODE_TEST_MODE` / `MOCK_OPENCODE_*` | モック opencode（`MODELS` / `SESSION_ID` / `ERROR` / `NOOP`） |
| `RATE_LIMIT_TEST_MODE` | `lib/rate-limit.sh` のテストモード |
| `OPENCODE_CONFIG_CONTENT` | opencode 設定（グローバル設定より優先）。下記「無人で回す」で使う |
| `PR_BODY_SYNCED_FILE` / `PR_CONTINUATION_COMMENTED_FILE` | 1 プロセス 1 度だけ行う同期・投稿のマーカー |

### CI ジョブ構成（`ci.yml`）

| ジョブ | OS | 内容 |
| ---- | ---- | ---- |
| `lint-bash` | Ubuntu + Windows | `bash -n` + `shellcheck -x` |
| `lint-ps` | Windows | PowerShell 構文（`install.ps1`） |
| `install-test` | Windows | `install.ps1` の配置物とハッシュ一致 |
| `mock-test` | Ubuntu + Windows | `gh-app/tests/run.sh` と `test.sh`（完全 offline） |
| `lint-ts` | Ubuntu | `tsc --noEmit` |
| `plugin-smoke` | Ubuntu + Windows | `test/smoke.sh`（要 node/npm/pwsh） |
| `e2e-opencode` | **Windows** | 実 opencode で `git vc` を叩く（要 jq / timeout / opencode） |

lint の対象外（注意）: `docker-run.sh` / `test/smoke.sh` / `test/e2e-opencode.sh` は
`bash -n` も shellcheck も回らない。

### プラットフォーム前提

- **Windows / Git Bash 前提**: `install.ps1`、`BASH_EXE` の既定値
  （`C:/Program Files/Git/bin/bash.exe`）、`get-token.sh` の WSL `/mnt/<drive>/` 変換、
  `driver_needs_relaunch`（`MSYSTEM` / `WSL_DISTRO_NAME` / `wslpath`）。
  Linux 用の `install.sh` は未実装（issue #4）。
- **GNU 系前提**: `date -d`（`get-token.sh:94`）、`base64 -d`（`lib/gh-api.sh`）、
  `mapfile` / `awk`（`api-commit.sh`）、`${line,,}`（`lib/rate-limit.sh`）。
  macOS/BSD では動かない。
- `.gitattributes` が LF 固定しているのは `*.sh` と `gh-app/app.env.example` だけ。

### 無人で回すときの既知の脆さ

1. **入れ子の `opencode run` は非対話**。opencode の permission で `ask` は自動拒否、
   `deny` はブロックになる。ユーザーの `~/.config/opencode/opencode.jsonc` に
   `ask` / `deny` があると、モデルは権限要求で作業を進められず `.commit-msg` を
   書かずに終わる → ドライバは「no complete work」として次のモデルへ引き継ぐ
   （以下同じ）。対処は `OPENCODE_CONFIG_CONTENT`（グローバル設定より後に
   読み込まれる）か `opencode run --auto`。
2. **`gh_api_request_review` は `{"reviewers":[]}` を投げる**（`lib/gh-api.sh`）。
   GitHub は空配列を 422 で弾くので、レビュー依頼は実質失敗し `WARNING` だけ残る。
3. **`api-commit.sh` 末尾の `git pull`** に `GIT_TERMINAL_PROMPT=0` が無い。
   credential helper 未設定で単体実行すると TTY で入力待ちになる。
4. **`bin/conahcnuj.sh` のバグ報告先は `nahcnuj/conahcnuj` 固定**（`:414`）。
   失敗は必ずこのリポジトリの issue になる（`issue-driver.yml` は bot 名義の issue を
   スキップするので、報告 issue が自動対応されることはない）。
5. **想定外の停止**: `git fetch origin <branch>` の直後（`:509` / `:525`）に
   `|| true` が無く、ref 作成直後の伝播遅延で `set -e` により終了しうる。
6. **`lib/gh-api.sh` の HTTP ステータス解析**はヘッダ 1 行目から 3 桁の値を取る。
   `HTTP/2 200` は読めるが `HTTP/1.1 200 OK` 形式だと空になり、成功でも 1 を返す。

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
  `CONAHCNUJ_COMMIT_MODEL` があれば `api-commit.sh` が本文へ `Model: <ラベル>` trailer を足す。OpenCode 上の `git vc` はプラグインがラベルを入れる。未設定なら trailer は付かない。
  `git vc` はプラグインが注入する git alias（組み込みの上書きは不可のため新規名 `vc`）。
  owner/repo/branch は `git remote` と現在ブランチから自動検出される。
- `api-commit.sh` の仕様:
  - 1 実行でブランチ先端に Verified コミットを **1 件だけ**作る（author は bot、committer は GitHub・署名付き）。`git add -A`＋`git commit -m` と収集内容は同じだが、作成場所（GitHub サーバー側）が違うため署名付きになる。
  - 無印は staged の内容を index（`git show :path`）から読む（`git commit` 相当。新規ファイルは `git add` でステージする）。`-a` は tracked の作業ツリー変更を読む（untracked 除外。`git commit -a` 相当。削除・リネーム対応）。
  - 注意: `-a` はコミット操作であり、ステージングでは無い。収集と Verified コミット作成を1実行で行う（中間ステージは作らない）。
  - `--delete <path>`（明示削除）、`--create-branch`（デフォルトブランチ起点で ref を作成。新規ブランチ用）、`--dry-run`（API を呼ばず収集結果のみ表示。token/network 不要）。
  - 既存ブランチへの追記のみ。履歴の書き換え・force-push はしない。unsigned コミットが既にあるブランチは、先に `git fetch` → `git reset --hard` で作り直してから使うこと。
- `git push` で unsigned コミットを送らない。`api-commit.sh` はコミットを直接リモートブランチに作成するため push 不要。ローカル同期は `git fetch origin` → `git reset --hard origin/<branch>`。