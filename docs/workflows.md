# GitHub Actions

`.github/workflows/` の各ワークフローです。このリポジトリのポリシーとして、利用する
`actions/*` は **full-length SHA でピン留め**します。

| ファイル | 名前 | 触発 | 役割 |
| --- | --- | --- | --- |
| `ci.yml` | CI | push to main / PR | lint・offline テスト・型チェック・smoke・e2e・docs ビルド |
| `issue-driver.yml` | Issue auto-drive | issue open/reopen、非 approve の review、required checks（CI）失敗、手動、`workflow_call` | ドライバを Actions 上で実行 |
| `weekly-self-improvement.yml` | Weekly auto-drive self-improvement | schedule（月曜） | 直近の auto-drive 実行ログを解析し、findings を Project とドライバへ引き渡す |
| `auto-merge.yml` | Owner-approved auto-merge | owner が approve | 再利用 workflow を呼び出してマージ |
| `owner-approved-auto-merge.yml` | Owner-approved auto-merge | `workflow_call` | マージ処理本体（他リポジトリからも利用可） |
| `setup.yml` | conahcnuj setup | `workflow_call` / 手動 | リポジトリが conahcnuj を実行できる状態か検証する |
| `pages.yml` | Docs to GitHub Pages | push to main / 手動 | `docs/` を GitHub Pages へ配信 |

## CI（`ci.yml`）

| ジョブ | チェック名（context） | ランナー |
| --- | --- | --- |
| `lint-bash` | `Lint shell scripts (ubuntu-latest)` / `Lint shell scripts (windows-latest)` | Ubuntu / Windows |
| `lint-ps` | `Check install.ps1 syntax` | Windows |
| `install-test` | `install.ps1 deployment test` | Windows |
| `mock-test` | `Mock tests (no secrets / no network) (<os>)` | Ubuntu / Windows |
| `lint-ts` | `Typecheck opencode plugin` | Ubuntu |
| `plugin-smoke` | `Plugin runtime smoke test (<os>)` | Ubuntu / Windows |
| `docs` | `Build docs site` | Ubuntu |
| `e2e-opencode` | `E2E opencode run (opencode free model)` | Windows |

`main` の ruleset が要求する **必須ステータスチェック**は次のとおりです
（これらが green でない PR はマージできません）:

1. `Lint shell scripts (ubuntu-latest)`
2. `Lint shell scripts (windows-latest)`
3. `Check install.ps1 syntax`
4. `E2E opencode run (opencode free model)`
5. `Typecheck opencode plugin`

加えて `main` ではコミット署名が必須（`required_signatures`）です。unsigned の
`git commit` は通らないため、コミットは [api-commit.sh](cli.md#api-commitsh) /
[git vc](plugin.md#git-vc) で作ります。

`mock-test` は秘密鍵・ネットワーク不要の offline 検証のみで、実トークンの検証は
CI では行いません。

## Issue auto-drive（`issue-driver.yml`）

- 触発: issue の `opened` / `reopened`、open で draft でない同リポジトリ PR への
  **approve 以外の** review（`submitted` / `edited` / `dismissed`）、同リポジトリ
  PR の required checks（`CI` workflow）失敗、手動実行
  （`workflow_dispatch` + `number` 入力）
- required checks の失敗は `check_run` / `check_suite` ではなく `CI` の
  `workflow_run`（`completed`）で拾い、`conclusion == 'failure'` かつ
  `event == 'pull_request'` かつ head が同リポジトリのときだけドライバを起動する。
  前者はドライバ自身の run（`Issue auto-drive`）でも発火して自己再帰するため。
  起動されたドライバは制約を読み直し、失敗していれば修正ラウンドをエージェントへ
  渡す
- bot（`user.type == Bot`）が作った issue / review は再帰防止のためスキップ。
  例外は `self-improvement` ラベル付きの issue（週次 findings）で、自己研鑽
  ループだけは自分の入口として起動できる
- `timeout-minutes: 60` と `CONAHCNUJ_MAX_SECONDS=3540` をセットで持ち、
  ランナーに切られる前にドライバが自己終了してバグ報告を残す
- 必要な repo secrets: `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` /
  `PRIVATE_KEY`（PEM 全文）。PEM は `$RUNNER_TEMP` へ書き出して `app.env` を組み立てる
- `GITHUB_TOKEN` の権限は `contents: read` のみ。書き込み（ブランチ・Verified
  コミット・PR・レビュー依頼・コメント・バグ報告 issue）はすべて App の
  インストールトークンで行う
- environment `conahcnuj` を使用
- 同一 issue/PR に対する実行は concurrency で直列化される

### 再利用 workflow の入力（`workflow_call`）

他リポジトリはこの workflow を呼び出して自分の issue / PR を駆動できる
（makamujo のローカル auto-drive パターンの置き換え）:

| 入力 | 必須 | 既定 | 内容 |
| --- | --- | --- | --- |
| `number` | ○ | - | 駆動する issue / PR 番号 |
| `repository` | - | 呼び出し側 | `owner/name` 形式の対象リポジトリ |
| `environment` | - | `conahcnuj` | App の secrets を持つ environment 名 |

secret（`APP_ID` / `INSTALLATION_ID` / `PRIVATE_KEY`）は必須。同一
organization / enterprise 内なら `secrets: inherit`、それ以外は名前付きで渡す。
`environment` は run の所属リポジトリ（＝呼び出し側）で解決されるため、
呼び出し側はその environment に App の secrets を持たせる。

```yaml
jobs:
  drive:
    uses: nahcnuj/conahcnuj/.github/workflows/issue-driver.yml@main
    with:
      number: 123
    secrets: inherit
```

振る舞い:

- ドライバの checkout は呼び出し側ではなくこの workflow 自身
  （`job.workflow_repository` at `job.workflow_sha`）から取るため、
  呼び出し側に `bin/` / `gh-app/` / `lib/` は不要
- 駆動対象がドライバのリポジトリと異なる場合（他リポジトリからの呼び出し）は、
  対象リポジトリを `target/` にも checkout し、ドライバをその中で実行する。
  するとブランチ作成・fetch・Verified コミットも、エージェントの編集も、
  ローカル実行と同じく対象リポジトリに対して行われる
- バグ報告 issue は常にドライバのリポジトリ（`nahcnuj/conahcnuj`）へ作られるが、
  本文の「Issue/PR」行は実際に駆動した対象（`repository`）を指す（#306）
- `number` が渡されればジョブは実行される（呼び出し側のイベント種別に
  依らない）。`repository` 未指定なら呼び出し側リポジトリを駆動する
- `GITHUB_TOKEN` の権限は `contents: read` のみ。書き込みはすべて、
  自リポジトリの実行と同じく App のインストールトークンで行う

## Weekly auto-drive self-improvement（`weekly-self-improvement.yml`）

毎週、直近 1 週間の `issue-driver.yml` 実行ログを解析し、次の週の改善 issue に
取り込む自己研鑽ループです。詳細は [self-improvement.md](self-improvement.md)。

- 触発: schedule のみ（既定 月曜 01:17 UTC）。人手の入力は無い
- 権限: `GITHUB_TOKEN` の `actions: write` / `issues: write` に加え、findings
  issue を App 名義で作るため repo secrets `APP_ID` / `INSTALLATION_ID` /
  `APP_SLUG` / `PRIVATE_KEY` を使う（`GITHUB_TOKEN` で作った issue は workflow
  を起動できず、`issues: opened` でドライバを動かせないため）
- ロジックの本体は `bin/auto-drive-workflow.sh`（`gh` API でのログ収集 →
  レポート作成 → トラッキング issue へ公開 → actionable 時に findings issue を
  更新し `self-improvement` を付与）。トラッキング issue と findings issue は
  Projects V2 board の item として board に載せる。`GITHUB_TOKEN` は
  Projects API に到達できないため、repository の **Projects** 権限を持つ App の
  インストールトークン（`GH_APP_TOKEN`）で repository Projects API を叩く。
  board は `vars.PROJECT_NUMBER` で指定するか `vars.PROJECT_TITLE` で探し作成する。
  解決できなければ組み込み auto-add にフォールバックする。ドライバを再帰起動
  しない衛生ルールは
  [self-improvement.md](self-improvement.md#ループの衛生再帰しない理由) を参照
- checkout は full-length SHA でピン留めしたうえで `ref: github.ref` を渡す。
  再実行は `github.sha`（最初の試行のコミット）を使い回すため、既定のままだと
  マージ済みの修正が効かず同じ失敗を繰り返す。ブランチ先端を取ることで
  schedule も再実行も現在のコードで動く

## Owner-approved auto-merge（`auto-merge.yml` + `owner-approved-auto-merge.yml`）

owner が open 中の draft でない PR を approve すると auto-merge を有効化し、
必要な checks が green ならその場で（green でなければ達成後に）マージします。
**マージ方法は `merge` / `squash` / `rebase`** で、既定は `merge` です。

### 再利用 workflow の入力（`workflow_call`）

| 入力 | 必須 | 既定 | 内容 |
| --- | --- | --- | --- |
| `repository` | ○ | - | `owner/name` 形式の対象リポジトリ |
| `pr-number` | ○ | - | PR 番号 |
| `head-sha` | ○ | - | approve された head コミット |
| `merge-method` | - | `merge` | `merge` / `squash` / `rebase` |
| `post-merge-dispatch` | - | `''` | **即時マージが成功したとき**だけ `gh workflow run` する workflow 名 |

呼び出し側は `pull_request_review` を購読し、`contents: write` /
`pull-requests: write`（`post-merge-dispatch` を使うなら `actions: write`）を
許可します。secret の `inherit` は不要（利用側の `GITHUB_TOKEN` を使う）。

```yaml
jobs:
  enable:
    uses: nahcnuj/conahcnuj/.github/workflows/owner-approved-auto-merge@main
    with:
      repository: ${{ github.repository }}
      pr-number: ${{ github.event.pull_request.number }}
      head-sha: ${{ github.event.pull_request.head.sha }}
```

振る舞い:

- 承認された head に一致するときだけ **即時マージ**を試す（`--match-head-commit`）。
  CI が既に green ならその場でマージされる
- 即時マージが拒否された場合（CI がまだ green でない・head が base より
  遅れているなど）は `gh pr merge --auto` で **ネイティブ auto-merge** を有効化して
  ジョブを終える。CI の完了待ちは GitHub 側で行われるため、ジョブは CI を待たない
  （issue #269）。リポジトリ設定で **Allow auto-merge** が必要
- マージ自体は `GITHUB_TOKEN` で行う。`GITHUB_TOKEN` のマージは push イベントを
  発生させないので、デプロイが必要なリポジトリは `post-merge-dispatch` で起動する
  （実際にマージされたと確認できたときだけ起動。auto-merge を有効化しただけの
  場合はまだマージされていないため起動しない）

## GitHub Pages（`docs/` の配信）

`pages.yml` は `docs/` をビルドして GitHub Pages へデプロイします。

- 触発: push to `main` と `workflow_dispatch`（PR のチェックとしては動かさない）
- `docs/build.py` がリンク検証 + HTML 生成を行い、`_site/` を
  `actions/upload-pages-artifact` → `actions/deploy-pages` で公開する
- 権限: `contents: read` / `pages: write` / `id-token: write`
- コンテンツは常に最新版のみ（バージョン切り替えなし）

**初回のみ**: リポジトリの Settings → Pages → **Source = GitHub Actions** を
選ぶ必要があります（未設定だと deploy ステップが失敗します）。

CI 側の docs ジョブ（`Build docs site`）は同じビルドを PR でも検証しますが、
必須チェックには入っていません。

## セットアップの検証（`action.yml` + `setup.yml`）

リポジトリ直下の `action.yml` は、リポジトリが conahcnuj を実行できる状態かを
README の Getting started の手順に沿って検証する composite action です。準備が
できていれば正常終了（exit 0）します。

チェック内容:

1. repo secrets `APP_ID` / `INSTALLATION_ID` / `PRIVATE_KEY` が揃っている
2. App の秘密鍵で JWT を署名し、インストールトークンを取得できる（App が作成済み
   で対象リポジトリにインストールされている）
3. App の slug と bot ユーザー ID を解決できる
4. **Allow auto-merge** が有効か（owner-approved auto-merge を使う場合のみ必要。
   無効でも warning で、失敗にはしない）

`setup.yml` はこの action を `workflow_call` で呼ぶ再利用 workflow です。他リポジトリ
からは次のように呼び出せます（`APP_ID` / `INSTALLATION_ID` / `PRIVATE_KEY` を
渡す。同一 organization / enterprise なら `secrets: inherit`）:

```yaml
jobs:
  setup:
    uses: nahcnuj/conahcnuj/.github/workflows/setup.yml@main
    with:
      environment: conahcnuj
    secrets: inherit
```

`setup.yml` の `environment` 入力（必須）で secrets を持つ environment を指定します。
composite action は `secrets` context を読めないため、
action へは必ず入力として渡します（`setup.yml` も同じ）。action だけを通常の
workflow step として使うこともできます:

```yaml
steps:
  - uses: nahcnuj/conahcnuj@main
    with:
      app-id: ${{ secrets.APP_ID }}
      installation-id: ${{ secrets.INSTALLATION_ID }}
      private-key: ${{ secrets.PRIVATE_KEY }}
```

`issue-driver.yml` / `owner-approved-auto-merge.yml` 自体は再利用 workflow として
このリポジトリに置かれているので、利用側に複製する必要はありません（呼び出し方は
上の各節を参照）。`setup.yml` が、それらを動かす前提の設定を検証します。

## 関連ページ

- [driver.md](driver.md) - ドライバの挙動（check 待ち・引き渡し）
- [environment.md](environment.md) - workflow 内の変数
- [cli.md](cli.md) - Verified コミット（署名必須ルール対応）
