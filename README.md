# conahcnuj

GitHub App として git 操作・認証を行うための、Git + opencode 設定をまとめたリポジトリ。

GitHub App「conahcnuj」のインストールトークンを発行し、それを利用して:

- `gh` CLI / GitHub API が **App 名義（`conahcnuj[bot]`）** で動く
- opencode 内の git 操作が **App 名義** で行われる

## 構成

```
.
├── gh-app/                    # シェルスクリプト群（App トークン発行・認証まわり）
│   ├── get-token.sh           #   JWT 署名 → インストールトークン取得（キャッシュ付き）
│   ├── git-credential-helper.sh  # git 用 credential helper
│   ├── setup-git.sh           #   リポジトリに bot 向け git config を適用
│   ├── api-commit.sh          #   GraphQL（createCommitOnBranch）で Verified コミットを作成
│   ├── bot-user-id.sh         #   bot アカウントの user ID を出す（app.env → キャッシュ → 公開 API）
│   ├── tests/                 #   offline モックテスト（run.sh がランナー。秘密鍵・ネットワーク不要）
│   ├── app.env                #   実設定（gitignore 対象・リポジトリ管理外）
│   └── app.env.example        #   設定テンプレート
├── bin/conahcnuj.sh           # issue駆動自律開発ドライバ本体
├── lib/                       # ドライバ用ライブラリ（GitHub API / opencode / レートリミット）
├── plugins/gh-app-token.ts    # opencode プラグイン（GH_TOKEN / GIT_CONFIG_* を注入）
├── test/                      # プラグインの smoke テスト・e2e（opencode の自動ロード対象外）
├── tests/                     # ドライバの offline モックテスト
├── test.sh                    # tests/ のランナー
├── Dockerfile                 # conahcnuj 実行用の隔離イメージ（opencode 同梱）
├── docker-run.sh              # そのイメージでドライバを走らせるラッパー
├── install.ps1                # グローバル設定（~/.config/opencode）へ配置＋ conahcnuj コマンド配備
├── .github/actions/install-opencode/action.yml  # opencode を入れる composite action（CI 専用）
├── .github/workflows/ci.yml           # GitHub Actions (Ubuntu / Windows)
├── .github/workflows/issue-driver.yml # issue を open されたら自動でドライバ実行
├── .github/workflows/auto-merge.yml   # owner 承認後にマージ workflow を呼び出す
├── .github/workflows/owner-approved-auto-merge.yml # 再利用用 auto-merge workflow
├── .gitattributes             # *.sh と app.env.example を LF 固定（CRLF は shebang を壊す）
├── .dockerignore              # app.env・キャッシュ・テストをイメージに載せない
├── .gitignore
└── AGENTS.md
```

`install.sh`（Linux/macOS 版）は未提供です（[#4](https://github.com/nahcnuj/conahcnuj/issues/4)）。
Linux では下の「隔離環境で実行する（Docker）」を使うか、`gh-app/`・`bin/`・`lib/`・`plugins/`
を手動で配置してください。

## 仕組み

1. `get-token.sh` が GitHub App の秘密鍵で JWT を署名し、
   `POST /app/installations/{id}/access_tokens` でインストールトークン（1時間有効）を取得。
   取得済みなら有効期限内はキャッシュ（`gh-app/token.cache`）を返す。
2. opencode プラグイン `plugins/gh-app-token.ts` が `shell.env` フックで
   `GH_TOKEN` と `GIT_CONFIG_*` を注入する。`GIT_CONFIG_*` は 5 件で、種別ごとに
   `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` という
   環境変数名で渡す（git の `GIT_CONFIG_COUNT` 規約）。

   | 設定 | 値 |
   | ---- | ---- |
   | `user.name` | `<app-slug>[bot]` |
   | `user.email` | `<bot user id>+<app-slug>[bot]@users.noreply.github.com` |
   | `credential.helper` | `!<BASH_EXE> <gh-app>/git-credential-helper.sh` |
   | `commit.gpgsign` | `false`（署名鍵が無いので true にすると `git commit` 自体が失敗する） |
   | `alias.vc` | `!<BASH_EXE> <gh-app>/api-commit.sh`（`git vc` = Verified コミット作成） |

   プラグインはトークンを **in-process で** 取得する（`get-token.sh` を起動しない。JWT の
   RS256 署名とキャッシュ読み出しを TS で実装しており、`token.cache` の形式は共有）。
   bot の user ID も插件内の `resolveBotUserId()` が `gh-app/bot-id.cache` 経由で解決する
   （`gh-app/bot-user-id.sh` はドライバ起動時の `setup-git.sh` からのみ使う）。
   `BASH_EXE` は上の credential helper / `alias.vc` のコマンド文字列に使う
   Windows の bash パスであり、トークン取得には使わない。

3. `git commit` はプラグインの `tool.execute.before` がブロックする。代わりに `git vc`
   （`api-commit.sh`）で Verified コミットを作る。

## Verified コミットを作る（api-commit.sh）

`gh-app/api-commit.sh` は GitHub GraphQL の `createCommitOnBranch` を使い、ブランチに
**Verified 署名のついたコミット**を 1 件作成する。コミットは GitHub 側が作成するため、
「Commits must have verified signatures」等のブランチルールを満たす。

なぜ普通の `git commit` ではダメなのか: opencode 上の git は App 名義で動き、
署名鍵を持たない。`commit.gpgsign=false` なら unsigned コミットになりブロックされ、
`true` に変えても鍵が無いため `git commit` 自体が失敗する。
bot アカウントに GPG 鍵は登録できないため、Verified にするには API 経由で
GitHub 自身にコミットを作成させるしかない。

```sh
bash gh-app/api-commit.sh <owner>/<repo> <branch> -m "message" [--delete path/to/removed]
bash gh-app/api-commit.sh -m "message" -a            # tracked の作業ツリー変更（git commit -a 相当）
bash gh-app/api-commit.sh -m "message"               # staged の内容（git commit 相当）
bash gh-app/api-commit.sh -m "message" --create-branch  # デフォルトブランチ起点で ref を作成
bash gh-app/api-commit.sh -m "message" --dry-run     # 収集結果のみ表示（token / ネットワーク不要）
```

- `-d` は `--delete` の短縮形。
- 1 実行でブランチ先端にコミットを **1 件だけ** 作る（既存ブランチへの追記のみ。
  履歴の書き換え・force push はしない）。
- 最後に `git pull origin <branch>` してローカルブランチを同期する。

`CONAHCNUJ_COMMIT_MODEL` にラベル（例: `Grok 4.7 (medium)`）が入っているとき、
コミット本文の末尾へ Git trailer `Model: <ラベル>` を足す。未設定なら足さない。
OpenCode ではプラグインがセッションの表示名と variant をこの変数へ入れる。
別のエージェントや手元のシェルは、同じ変数に好きな文字列を入れて使える。

## issue駆動自律開発（conahcnuj）

`bin/conahcnuj.sh`（`install.ps1` により `conahcnuj` コマンドとして配備）は、
指定した GitHub issue の解決を最後まで自律的に行うドライバです。

```
conahcnuj <issue番号>        # issue から開始
conahcnuj <PR番号>           # 入力が PR なら自動で引き継いで再開
```

流れ:

0. issue の内容を読み、最新のデフォルトブランチからフィーチャーブランチを
   作成して実装する。コミットメッセージは必ずコーディングエージェントが
   決める（`.commit-msg`。未指定ならドライバはコミットしない）。ブランチ名も
   エージェントが決められる（`.branch-name`。未指定時のみドライバが
   `conahcnuj/<番号>-<スラッグ>` で採番する）。最初のモデルが作業中に
   rate limit などのエラーで進められなくなった場合、opencode の同じ
   `sessionID` と現在の作業ツリーを次のモデルへ引き継ぎ、完了まで継続する。
   セッションIDを取得できなかった場合だけ新しいセッションで作業ツリーから再開する。
1. PR を作成し、レビュアー以外の制約（status checks・mergeable）が通るまで
   待ってからレビューを依頼する。PR の本文はクローズ対象 issue の内容を基に
   `Closes #<番号>` と合わせて自動生成され、既存 PR を再利用した場合も同期される。
2. レビューステータスをポーリングし、Comment / Request changes / 未解決の
   レビュースレッド（セキュリティレビューの指摘を含む）を検出したらモデルを
   使って対応し、api-commit.sh で Verified コミットを push して制約を再確認し、
   PR へ返信する。
3. PR が「Approved かつ全制約通過（ready to merge）」になるまで終了しない。
4. 異常終了時（タイムアウト・全モデル失敗・想定外エラー・CLOSED PR の再開など
   で PR を解決できずに終了コード非 0 で終わる場合）は、ドライバが
   **`nahcnuj/conahcnuj` へ**バグ報告 issue を自動作成する（`lib/gh-api.sh` の
   `gh_api_create_issue`。終了コード・対象 #番号（作業先リポジトリが別でも
   `owner/repo#番号` で一意）・ブランチ・HEAD・実行ログ末尾を含む）。
   対象リポジトリがどれであれ、報告先はこのリポジトリに固定されている。

ポーリング・リトライは GitHub のレートリミット（Retry-After /
X-RateLimit-Reset）とジッター付きスリープで調整される（`lib/rate-limit.sh`）。
ドライバ自身は自動マージを行わない。時間予算・ポーリング幅などの環境変数上書きや
offline テストモード（`CONAHCNUJ_TEST_MODE=1`）については
`bin/conahcnuj.sh` のヘッダーコメントを参照。

`CONAHCNUJ_REPO=owner/repo`、`CONAHCNUJ_MAX_SECONDS`、ポーリング幅などは
すべて省略可能です。

## issue の自動対応（GitHub Actions）

このリポジトリの `.github/workflows/issue-driver.yml` は、issue が open される
と上記ドライバを Actions 上で自動実行して対応を試みるワークフローです。
トリガーは 3 つあります。

- `issues: [opened, reopened]` — issue が立ったとき。
- `pull_request_review: [submitted, edited, dismissed]` — open 中の draft でない
  同一リポジトリの PR に、owner 以外から `approved` 以外の review が入ったとき
  （PR 番号でドライバを再開）。
- `workflow_dispatch`（入力 `number`: issue / PR 番号）— 手動実行。
  ドライバが PR に貼る「継続コメント」の URL はこれ（`inputs%5Bnumber%5D=<pr>`）。

同じ PR で実行中の場合は、concurrency により新しい実行を待機させます。
失敗時はドライバがバグ報告 issue を自動作成し、その issue（bot が開いたもの）
は再帰防止のためワークフローから除外されます。

- **タイムアウトは Actions 側で制御**します（ジョブの `timeout-minutes: 60`）。
  `CONAHCNUJ_MAX_SECONDS=3540` をその直下に設定し、ジョブが強制終了される前に
  ドライバが自己終了してバグ報告を残せるようにしています。予算を変えるときは
  両方を合わせて変更してください。
- ジョブは `environment: conahcnuj` を指定しています。GitHub 上でこの
  Environment に required reviewers を設定していると、**無人の実行が承認待ちで
  止まります**（自動対応が成立しなくなるので注意）。
- 必要な repo secrets: `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` /
  `PRIVATE_KEY`（App の秘密鍵 PEM）。runner 上の `GITHUB_TOKEN` は
  `contents: read` のみで、書き込み（ブランチ・コミット・PR・レビュー依頼・
  コメント）はすべてローカル実行と同じく App のインストールトークンで行われます。

## owner 承認後の自動マージ（GitHub Actions）

`.github/workflows/auto-merge.yml` は、owner（`author_association == OWNER`）が
open 中の draft でない PR を approve すると `owner-approved-auto-merge.yml`
（reusable workflow）を呼び出し、**checks が通った時点でマージ**します。

ネイティブ auto-merge（`enablePullRequestAutoMerge`）は integration token では
有効化できません（`Resource not accessible by integration`）。そのため
`gh pr checks --watch` で CI を待ち、`gh pr merge --match-head-commit` で自前
マージします（`GITHUB_TOKEN` のマージは `push` イベントを発生させないので、
デプロイが必要なら `post-merge-dispatch` で明示的に起動します）。

- 承認された head SHA が現在の head と一致しなければスキップ（承認後に push された
  場合の取りこぼし防止）。
- PR に check が 1 つも無い場合は即マージ、1 つでも失敗したら非 0 で終了。
- `auto-merge.yml` は `merge-method` を転送しません（`merge` 固定）。merge commit を
  許可しないリポジトリでは直接 `owner-approved-auto-merge.yml` を呼び出すこと。

### 他のリポジトリで使う（Reusable Workflow）

`.github/workflows/owner-approved-auto-merge.yml` は `workflow_call` で
再利用できる Workflow です。イベント検知は利用側で行い、中央の Workflow が
owner 承認条件と `gh pr merge` を実行します。`post-merge-dispatch` を使う場合は
`actions: write` も必要（呼び出し側の `permissions` で渡さないと
`gh workflow run` が 403 になります）。対象リポジトリには次のファイルを
追加します。

```yaml
name: Owner-approved auto-merge

on:
  pull_request_review:
    types: [submitted]

permissions:
  contents: write
  pull-requests: write
  actions: write # post-merge-dispatch を使う場合（使わないなら省略可）

jobs:
  enable:
    uses: nahcnuj/conahcnuj/.github/workflows/owner-approved-auto-merge@main
    with:
      repository: ${{ github.repository }}
      pr-number: ${{ github.event.pull_request.number }}
      head-sha: ${{ github.event.pull_request.head.sha }}
      # merge-method: squash      # merge commit を許可しない場合
      # post-merge-dispatch: cd.yml  # マージ後に起動する workflow
```

Reusable Workflow は利用側Workflowの `GITHUB_TOKEN` を使い、secret の
`inherit` は不要です。マージは `contents: write` で実行されます。

## 隔離環境で実行する（Docker）

自律実行（opencode が作業ツリーを自由に編集する）をホストから隔離したい場合は、
`Dockerfile` でビルドしたイメージ内でドライバを動かせます。opencode・git・
curl・openssl・ドライバ本体はイメージに同梱し、**秘密鍵と `app.env` は
イメージへ焼き込まず**実行時に読み取り専用でマウントします。

```sh
cd <対象リポジトリ>
bash <このリポジトリ>/docker-run.sh <issue-or-PR番号>
```

- 対象リポジトリは `/work` に **read-write** でバインドマウントされ、コンテナ内の
  ドライバがそこへコミットを push します（ホストのリポジトリは汚れます。clean にする
  のはコンテナ側の `git reset --hard origin/<branch>` 後）。
- `gh-app/app.env` から `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` /
  `PRIVATE_KEY_PATH` を読み、コンテナ用の `app.env`（`BASH_EXE=/usr/bin/bash`、
  鍵はマウント先）を生成して渡す。秘密鍵は `/run/secrets/app.pem` に読み取り
  専用でマウントする。
- opencode の設定・認証（`~/.config/opencode` / `~/.local/share/opencode`）が
  あれば **read-write** でロードする（ホストの認証情報と設定をコンテナから
  書き換えられる点に注意）。
- 上書き用の環境変数（`CONAHCNUJ_IMAGE` / `CONAHCNUJ_TARGET` /
  `CONAHCNUJ_APP_ENV` / `CONAHCNUJ_BUILD` / `OPENCODE_CONFIG_DIR` /
  `OPENCODE_DATA_DIR` / `CONAHCNUJ_DAEMON` / `CONAHCNUJ_NAME`、および
  `CONAHCNUJ_REPO` 等のドライバ設定）は `docker-run.sh` のヘッダーコメントを参照。

## インストール

前提:

- Windows + Git for Windows（`C:/Program Files/Git/bin/bash.exe`）
- opencode が `~/.config/opencode/` をグローバル設定として使う

Linux / macOS 向けの `install.sh` は未提供です（[#4](https://github.com/nahcnuj/conahcnuj/issues/4)）。

### 1. インストール

```sh
git clone <repo>.git
cd <repo>
powershell -ExecutionPolicy Bypass -File install.ps1
```

配置されるもの:

| 配置先 | 内容 |
| ---- | ---- |
| `~/.config/opencode/gh-app/` | `gh-app/*.sh`（プラグインが使う） |
| `~/.config/opencode/plugins/gh-app-token.ts` | opencode プラグイン |
| `~/.config/opencode/gh-app/app.env` | 既定は `app.env.example` から作成（要編集） |
| `~/.local/bin/conahcnuj` | ドライバ本体（`bin/conahcnuj.sh`） |
| `~/.local/gh-app/` `~/.local/lib/` | ドライバが使う `gh-app` と `lib`（プラグイン用とは別配置） |

### 2. `~/.local/bin` を PATH に入れる

`install.ps1` は PATH を変更しません。`~/.local/bin` が PATH に無いと `conahcnuj`
コマンドが見つかりません。

### 3. opencode を再起動

`gh-app/app.env` に実値を入れてから OpenCode を再起動する（プラグインは起動時ロード）。

## トラブルシューティング

- **`gh auth status` が自分のアカウントを表示する / `GH_TOKEN` が入っていない**
  プラグインがトークンを取得できていない。`app.env` の値と、キャッシュ
  `gh-app/token.cache` を確認する。プラグインは起動時にトークンを取りに行くので、
  `app.env` を直したら opencode を再起動する。
  `BASH_EXE` はトークン取得には使われない（プラグインが in-process で署名する）。
  credential helper や `git vc` が動かないときに確認する値で、Windows では素の
  `bash` が WSL に解決されることがあり、その場合は Git Bash のパスを明示する。
- **トークンが取れない**
  `bash gh-app/get-token.sh` を直接実行し、出力（`token.cache` 削除後に再実行）を確認。
- **`git vc` が `commit.gpgsign` で失敗する**
  プラグインは `commit.gpgsign=false` を注入する。`true` に上書きすると署名鍵が無い
  ため失敗する（`git vc` を使うのが正解）。
- **PR が ready to merge にならない**
  ドライバは APPROVED になるまで終了しません。branch protection の required reviewers を
  満たしていることを確認する（bot は自分の PR を承認できないため owner のレビューが必要）。
- **CI で実トークンの検証が無い**
  CI の `mock-test` は秘密鍵・ネットワーク不要の offline 検証のみ。実トークンの
  動作確認はローカルで `bash gh-app/get-token.sh` → `bash gh-app/setup-git.sh` を
  実行して確認する。