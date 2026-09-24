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
   `conahcnuj/<番号>-<スラッグ>` で採番する）。実装は使用可能な全モデルを
   順に試し、最初に作業ツリーへ変更を生んだモデルを採用する。
1. PR を作成し、レビュアー以外の制約（status checks・mergeable）が通るまで
   待ってからレビューを依頼する。PR の本文はクローズ対象 issue の内容を基に
   `Closes #<番号>` と合わせて自動生成され、既存 PR を再利用した場合も同期される。
2. レビューステータスをポーリングし、Comment / Request changes / 未解決の
   レビュースレッド（セキュリティレビューの指摘を含む）を検出したらモデルを
   使って対応し、api-commit.sh で Verified コミットを push して制約を再確認し、
   PR へ返信する。
3. PR が「Approved かつ全制約通過（ready to merge）」になるまで終了しない。
4. 異常終了時（タイムアウト・全モデル失敗・想定外エラー・CLOSED PR の再開など
   で PR を解決できずに終了コード非 0 で終わる場合）は、ドライバが conahcnuj
   リポジトリへバグ報告 issue を自動作成する（`lib/gh-api.sh` の
   `gh_api_create_issue`。終了コード・対象 #番号・ブランチ・HEAD・
   実行ログ末尾を含む）。作業中のリポジトリではなく conahcnuj 自身へ作るので、
   報告先は操作対象の GitHub App に権限が無くてもファイルできる。

ポーリング・リトライは GitHub のレートリミット（Retry-After /
X-RateLimit-Reset）とジッター付きスリープで調整される（`lib/rate-limit.sh`）。
自動マージは行わない。環境変数の上書き（時間予算・ポーリング幅）や
offline テストモード（`CONAHCNUJ_TEST_MODE=1`）については
`bin/conahcnuj.sh` のヘッダーコメントを参照。

`CONAHCNUJ_REPO=owner/repo`、`CONAHCNUJ_BUG_REPO=owner/repo`（バグ報告の
格納先。未設定時は `gh-app/app.env` の設定値、さらに無ければドライバ自身の
origin remote、異常終了時は GitHub App のインストールから導出、最後に作業中
リポジトリへフォールバック）、`CONAHCNUJ_MAX_SECONDS`、ポーリング幅などは
すべて省略可能です。

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