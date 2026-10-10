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
├── TODO.md                    # issue ごとの進捗ファイル（着手で作成・完了で削除。実行中のみ存在）
├── lib/                       # ドライバ用ライブラリ（GitHub API / opencode / 出力整形 / レートリミット）
├── plugins/gh-app-token.ts    # opencode プラグイン（GH_TOKEN / GIT_CONFIG_* を注入）
├── opencode/AGENTS.md         # opencode グローバルルール（コミットは git vc。install.ps1 が配置）
├── plugin-tests/               # プラグインのテスト（unit＋smoke＋e2e と install.ps1 の AGENTS.md merge。node/npm・pwsh・opencode が必要）
├── driver-tests/               # ドライバの offline モックテスト（run.sh がランナー。秘密鍵・ネットワーク不要）
│   └── run.sh                  #   driver-tests/ 全体のランナー
├── Dockerfile                 # conahcnuj 実行用の隔離イメージ（opencode 同梱）
├── docker-run.sh              # そのイメージでドライバを走らせるラッパー
├── install.ps1                # グローバル設定（~/.config/opencode）へ配置＋ conahcnuj コマンド配備
├── docs/                      # AI 向けリファレンス（GitHub Pages で配信。build.py が検証・HTML 化）
├── .github/workflows/ci.yml           # GitHub Actions (Ubuntu / Windows)
├── .github/workflows/issue-driver.yml # issue を open されたら自動でドライバ実行
├── .github/workflows/auto-merge.yml   # owner 承認後に auto-merge を有効化
├── .github/workflows/owner-approved-auto-merge.yml # 再利用用 auto-merge workflow
├── .github/workflows/pages.yml        # docs/ を GitHub Pages へデプロイ
├── .gitignore
└── AGENTS.md
```

## ドキュメント（GitHub Pages）

アプリとその API（設定・CLI・ドライバ・プラグイン・環境変数・ワークフロー）の
リファレンスを `docs/` に置き、GitHub Pages で配信しています。常に最新版のみで、
バージョン切り替えはありません。

- サイト: <https://nahcnuj.github.io/conahcnuj/>
- 機械可読な索引: <https://nahcnuj.github.io/conahcnuj/llms.txt>
- 各ページは Markdown 原文（同じパスの `.md`）と HTML の両方で開けます

`docs/*.md` がソースで、`.github/workflows/pages.yml` が push to main のたびに
`docs/build.py`（リンク検証 + HTML 生成 → `_site/`）を実行してデプロイします。
**初回のみ** Settings → Pages → Source = **GitHub Actions** を設定してください。
CI の `Build docs site` ジョブが同じビルドを PR でも検証します。ローカルでは
`pipenv sync && pipenv run python3 docs/build.py`（検証のみは
`python3 docs/build.py --check`）で確認できます。

## 仕組み

1. `get-token.sh` が GitHub App の秘密鍵で JWT を署名し、
   `POST /app/installations/{id}/access_tokens` でインストールトークン（1時間有効）を取得。
   取得済みなら有効期限内はキャッシュ（`gh-app/token.cache`）を返す。
2. opencode プラグイン `plugins/gh-app-token.ts` が `shell.env` フックで
   `GH_TOKEN` と `GIT_CONFIG_*`（user.name / user.email / credential.helper /
   commit.gpgsign / alias.vc）を注入。
3. `experimental.chat.system.transform` フックで「コミットは `git vc`」という
   規則を全セッションのシステムプロンプトへ常時注入し、`tool.execute.before`
   で `git commit` と `api-commit.sh` の直接実行を検知して `git vc` へ誘導する。
4. `install.ps1` は `opencode/AGENTS.md` を `~/.config/opencode/AGENTS.md` へ
   管理ブロックとしてマージし、リポジトリごとの指示が無い場合でも
   エージェントが `git vc` を選べるようにする（既存の内容は保持）。

## Verified コミットを作る（`git vc`）

コーディングエージェントは `git vc` でコミットする。`git vc` はプラグインが
注入する git alias で、`gh-app/api-commit.sh` を正しい owner/repo/branch 付きで
呼び出すラッパー。`git add` でステージしてから `git vc -m "<message>"`、
tracked の作業ツリー変更をまとめるなら `git vc -m "<message>" -a`
（`git commit` / `git commit -a` と収集内容は同じ）。`api-commit.sh` の直接実行は
プラグインの `tool.execute.before` がブロックし、`git vc` へ誘導する。

`gh-app/api-commit.sh` は GitHub GraphQL の `createCommitOnBranch` を使い、ブランチに
**Verified 署名のついたコミット**を 1 件作成する。コミットは GitHub 側が作成するため、
「Commits must have verified signatures」等のブランチルールを満たす。

なぜ普通の `git commit` ではダメなのか: opencode 上の git は App 名義で動き、
署名鍵を持たない。`commit.gpgsign=false` なら unsigned コミットになりブロックされ、
`true` に変えても鍵が無いため `git commit` 自体が失敗する。
bot アカウントに GPG 鍵は登録できないため、Verified にするには API 経由で
GitHub 自身にコミットを作成させるしかない。

`CONAHCNUJ_COMMIT_MODEL` に値（例: `xai (grok-4.7/medium)`）が入っているとき、
コミット本文の末尾へ Git trailer `Co-Authored-By: <値>` を足す。未設定なら足さない。
OpenCode ではプラグインがセッションの provider・model・effort を
`provider (model/effort)` の形でこの変数へ入れる（本文に既に
`Co-Authored-By` があれば足さない）。
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
   作成して実装する。プロンプトは「issue ないし PR を owner の Approve まで
   導くのが目的・エージェントの担当は作業ツリーの変更、ブランチ名・コミット・
   push・PR の作成・レビュー依頼はドライバ」という 1 段落だけを全ラウンドに
   共通で伝える。指示を積み増さないのは、コーディングエージェントの仕事を
   邪魔しないため（禁止コマンドの一覧や「これは成果物ではない」という注意を
   書くと、エージェントはそれが任務だと誤解してコードを書かなくなる）。
   一方、決定論的に収集できる情報（issue / PR の本文、再開時 PR の未解決
   レビュースレッド、`README.md` / `AGENTS.md` など `CONAHCNUJ_CONTEXT_FILES`
   のファイル）は指示ではなく**材料**として `Collected context:` という別枠で
   最初のプロンプトに同梱し、エージェントが初動で拾う手間を省く。例外はレビュー
   スレッドへの返信で、これだけはエージェント自身が行う。契約には足さず、
   フィードバック対応ラウンドの追加コンテキストで各スレッドの comment id と
   返信エンドポイントを添えて「返信し、必要なら修正する」と伝える。
   コミットメッセージは必ずコーディングエージェントが決める（`.commit-msg`。
   ドライバが使う 1 行。未指定ならドライバはコミットしない。メッセージだけ
   書いて作業ツリーが無変更なら no work として次のモデルへ引き継ぐ）。
   ブランチ名もエージェントが決められる（`.branch-name`。未指定時のみドライバが
   `conahcnuj/<番号>-<スラッグ>` で採番する）。最初のモデルが作業中に
   rate limit などのエラーで進められなくなった場合、opencode の同じ
   `sessionID` と現在の作業ツリーを次のモデルへ引き継ぎ、完了まで継続する。
   セッションIDを取得できなかった場合だけ新しいセッションで作業ツリーから再開する。
   issue の進捗はリポジトリルートの `TODO.md`（生存期間は issue 毎）で管理・共有する。
   エージェントが着手時に作成し、作業中に更新し、完了して ready to merge するときに
   削除する（書式は問わない。）
1. PR を作成したら、まず **リポジトリ owner を reviewer にアサイン**して
   レビューを依頼し、その後にレビュアー以外の制約（status checks・mergeable）を
   ポーリングして、失敗していれば直す（人がレビューを引き受ける引き渡し点
   hand-off を先に作るので、CI が green になるのを待ってから依頼するより
   レビューが早く進む。#233）。依頼付けられて制約が通った時点でドライバは
   正常終了する（既に Approved なら「ready to merge」で終了する）。
   `TODO.md` がある状態では PR は **draft** として作られ、レビュー依頼をしない。
   削除されて初めてドライバが draft を解除してレビュー依頼するので、
   `TODO.md` がある限りエージェント自身で draft を解除できない（draft でない PR を
   作成できない）。ドライバは削除されるまでラウンドを重ねて実装を続ける。
   依頼の API が失敗を返しても PR を読み返して実際に依頼が入っているかを
   確認する（GitHub が記録した後の通信エラーは拒绝と区別できないため。#134）。
   PR の本文はクローズ対象 issue の内容を基に
   `Closes #<番号>` と合わせて自動生成され、既存 PR を再利用した場合も同期される。
2. 再開実行時に新しいレビュー意見（Comment / Request changes / 未解決の
   レビュースレッド。セキュリティレビューの指摘を含む）がある場合は、
   モデルを使って対応し、api-commit.sh で Verified コミットを push し、
   owner へレビューを再依頼してから制約を再確認して終了する。既知のレビュー
   意見は制約（status checks・mergeable）のポーリングを待たずに先に対応する
   （未解決スレッドが残る PR は、スレッドが片付くまで制約を満たせないため、
   先に待つと時間予算を無駄にするだけ。#219）。レビュースレッド
   への返信はエージェント自身が行い（ドライバは「Addressed the review
   feedback」のような代行コメントを投稿しない）、返信は bot 著者として
   レビュー fingerprint から除外されるので、自分の返信を新規意見と誤認して
   ループしない。対応ラウンドの追加コンテキストには各スレッドの comment id と
   返信エンドポイントを添える。
3. owner の Approve と merge は `auto-merge.yml` /
   `owner-approved-auto-merge.yml` の担当で、ドライバ自身は自動マージしない。
4. 異常終了時（タイムアウト・全モデル失敗・想定外エラー・CLOSED PR の再開・
   レビュー依頼の失敗で PR を引き渡せなかった場合など、終了コード非 0 で
   終わる場合）は、ドライバが対象
   リポジトリへバグ報告 issue を自動作成する（`lib/gh-api.sh` の
   `gh_api_create_issue`。終了コード・対象 #番号・ブランチ・HEAD・
   実行ログ末尾を含む）。

ポーリング・リトライは GitHub のレートリミット（Retry-After /
X-RateLimit-Reset）とジッター付きスリープで調整される（`lib/rate-limit.sh`）。
環境変数の上書き（時間予算・ポーリング幅）や
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

承認からマージまでのあいだに別の PR が base ブランチへ入ると、head が base に
遅れて GitHub が即時マージを拒否します。この Workflow はその場合に `--auto` で
マージをキューイングするので（head が最新に戻れば自動的にマージされる）、
ジョブが失敗にはなりません。キューイングもできない場合はエラーとして報告します。

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

`merge-method` は省略すると `merge` です。Merge commitを許可しないリポジトリでは、
`with` に `merge-method: squash` または `merge-method: rebase` を指定します。

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