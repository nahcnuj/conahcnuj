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
│   ├── tests/                 #   offline モックテスト（run.sh がランナー。秘密鍵・ネットワーク不要）
│   ├── app.env                #   実設定（gitignore 対象・リポジトリ管理外）
│   └── app.env.example        #   設定テンプレート
├── bin/conahcnuj.sh           # issue駆動自律開発ドライバ本体
├── lib/                       # ドライバ用ライブラリ（GitHub API / opencode / レートリミット）
├── plugins/gh-app-token.ts    # opencode プラグイン（GH_TOKEN / GIT_CONFIG_* を注入）
├── test/                      # プラグインの smoke テスト（opencode の自動ロード対象外）
├── tests/                     # ドライバの offline モックテスト
├── test.sh                    # tests/ のランナー
├── Dockerfile                 # conahcnuj 実行用の隔離イメージ（opencode 同梱）
├── docker-run.sh              # そのイメージでドライバを走らせるラッパー
├── install.ps1                # グローバル設定（~/.config/opencode）へ配置＋ conahcnuj コマンド配備
├── .github/workflows/ci.yml           # GitHub Actions (Ubuntu / Windows)
├── .github/workflows/issue-driver.yml # issue を open されたら自動でドライバ実行
├── .github/workflows/auto-merge.yml   # owner 承認後に auto-merge を有効化
├── .github/workflows/owner-approved-auto-merge.yml # 再利用用 auto-merge workflow
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
   で PR を解決できずに終了コード非 0 で終わる場合）は、ドライバが対象
   リポジトリへバグ報告 issue を自動作成する（`lib/gh-api.sh` の
   `gh_api_create_issue`。終了コード・対象 #番号・ブランチ・HEAD・
   実行ログ末尾を含む）。

ポーリング・リトライは GitHub のレートリミット（Retry-After /
X-RateLimit-Reset）とジッター付きスリープで調整される（`lib/rate-limit.sh`）。
ドライバ自身は自動マージを行わない。環境変数の上書き（時間予算・ポーリング幅）や
offline テストモード（`CONAHCNUJ_TEST_MODE=1`）については
`bin/conahcnuj.sh` のヘッダーコメントを参照。

`CONAHCNUJ_REPO=owner/repo`、`CONAHCNUJ_MAX_SECONDS`、ポーリング幅などは
すべて省略可能です。

## issue の自動対応（GitHub Actions）

このリポジトリの `.github/workflows/issue-driver.yml` は、issue が open される
と上記ドライバを Actions 上で自動実行して対応を試みるワークフローです。
open 中の draft でない同一リポジトリの PR に `approved` 以外の review が
submit・編集・dismiss された場合も、PR 番号でドライバを再開します。
同じ PR で実行中の場合は、concurrency により新しい実行を待機させます。
失敗時はドライバがバグ報告 issue を自動作成し、その issue（bot が開いたもの）
は再帰防止のためワークフローから除外されます。

- **タイムアウトは Actions 側で制御**します（ジョブの `timeout-minutes: 60`）。
  `CONAHCNUJ_MAX_SECONDS=3540` をその直下に設定し、ジョブが強制終了される前に
  ドライバが自己終了してバグ報告を残せるようにしています。予算を変えるときは
  両方を合わせて変更してください。
- 必要な repo secrets: `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` /
  `PRIVATE_KEY`（App の秘密鍵 PEM）。runner 上の `GITHUB_TOKEN` は
  `contents: read` のみで、書き込み（ブランチ・コミット・PR・レビュー依頼・
  コメント）はすべてローカル実行と同じく App のインストールトークンで行われます。

## owner 承認後の自動マージ（GitHub Actions）

`.github/workflows/auto-merge.yml` は、owner が open 中の draft でない PR を
approve すると auto-merge を有効化します。必要な status checks が既に green なら
その場でマージされ、まだ green でなければ条件達成後にマージされます。書き込みには
GitHub Actions の `GITHUB_TOKEN` を使用します。リポジトリ設定で
auto-merge が有効になっている必要があります。

### 他のリポジトリで使う（Reusable Workflow）

`.github/workflows/owner-approved-auto-merge.yml` は、`workflow_call` で
再利用できる Workflow です。イベント検知は利用側で行い、中央の Workflow が
owner 承認条件と `gh pr merge` を実行します。対象リポジトリには次のファイルを
追加します。

```yaml
name: Owner-approved auto-merge

on:
  pull_request_review:
    types: [submitted]

permissions:
  contents: write
  pull-requests: write

jobs:
  enable:
    uses: nahcnuj/conahcnuj/.github/workflows/owner-approved-auto-merge@main
    with:
      repository: ${{ github.repository }}
      pr-number: ${{ github.event.pull_request.number }}
      head-sha: ${{ github.event.pull_request.head.sha }}
```

Reusable Workflow は利用側Workflowの `GITHUB_TOKEN` を使い、secret の
`inherit` は不要です。呼び出し側の `permissions` で `contents: write` と
`pull-requests: write` を許可し、対象リポジトリの **Settings → General →
Pull Requests** で **Allow auto-merge** を有効にしてください。

## 隔離環境で実行する（Docker）

自律実行（opencode が作業ツリーを自由に編集する）をホストから隔離したい場合は、
`Dockerfile` でビルドしたイメージ内でドライバを動かせます。opencode・git・
curl・openssl・ドライバ本体はイメージに同梱し、**秘密鍵と `app.env` は
イメージへ焼き込まず**実行時に読み取り専用でマウントします。

```sh
cd <対象リポジトリ>
bash <このリポジトリ>/docker-run.sh <issue-or-PR番号>
```

- 対象リポジトリは `/work` にバインドマウントされ、コンテナ内のドライバが
  そこを操作する（ホストのリポジトリは直接汚さない）。
- `gh-app/app.env` から `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` /
  `PRIVATE_KEY_PATH` を読み、コンテナ用の `app.env`（`BASH_EXE=/usr/bin/bash`、
  鍵はマウント先）を生成して渡す。秘密鍵は `/run/secrets/app.pem` に読み取り
  専用でマウントする。
- opencode の設定・認証（`~/.config/opencode` / `~/.local/share/opencode`）が
  あれば読み込み、ホストと同じモデルを使える。
- 上書き用の環境変数（`CONAHCNUJ_IMAGE` / `CONAHCNUJ_TARGET` /
  `CONAHCNUJ_APP_ENV` / `CONAHCNUJ_BUILD` / `OPENCODE_CONFIG_DIR` /
  `OPENCODE_DATA_DIR`、および `CONAHCNUJ_REPO` 等のドライバ設定）は
  `docker-run.sh` のヘッダーコメントを参照。

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

### 2. opencode を再起動

`gh-app/app.env` に実値を入れてから OpenCode を再起動する。

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