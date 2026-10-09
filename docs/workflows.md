# GitHub Actions

`.github/workflows/` の各ワークフローです。このリポジトリのポリシーとして、利用する
`actions/*` は **full-length SHA でピン留め**します。

| ファイル | 名前 | 触発 | 役割 |
| --- | --- | --- | --- |
| `ci.yml` | CI | push to main / PR | lint・offline テスト・型チェック・smoke・e2e・docs ビルド |
| `issue-driver.yml` | Issue auto-drive | issue open/reopen、非 approve の review、手動 | ドライバを Actions 上で実行 |
| `weekly-self-improvement.yml` | Weekly auto-drive self-improvement | schedule（月曜） | 直近の auto-drive 実行ログを解析し、findings を Project とドライバへ引き渡す |
| `auto-merge.yml` | Owner-approved auto-merge | owner が approve | 再利用 workflow を呼び出してマージ |
| `owner-approved-auto-merge.yml` | Owner-approved auto-merge | `workflow_call` | マージ処理本体（他リポジトリからも利用可） |
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
  **approve 以外の** review（`submitted` / `edited` / `dismissed`）、
  手動実行（`workflow_dispatch` + `number` 入力）
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
  更新し `self-improvement` を付与）。Project への投入は Project 側の組み込み
  auto-add（`label:self-improvement`）が行い、Projects API は呼ばない。ドライバを
  再帰起動しない衛生ルールは
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
| `post-merge-dispatch` | - | `''` | マージ成功後に `gh workflow run` する workflow 名 |

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

- 承認からマージまでのあいだに base へ別の PR が入ると即時マージが拒否される
  ため、`gh pr merge --auto` でキューイングしてから成功させる
- 自 workflow・ドライバ（`IGNORED_WORKFLOWS`、既定 `Issue auto-drive`）の
  check は待たない（互いの check を待ち合ってデッドロックするため）
- マージ自体は `GITHUB_TOKEN` で行う。`GITHUB_TOKEN` のマージは push イベントを
  発生させないので、デプロイが必要なリポジトリは `post-merge-dispatch` で起動する

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

## 関連ページ

- [driver.md](driver.md) - ドライバの挙動（check 待ち・引き渡し）
- [environment.md](environment.md) - workflow 内の変数
- [cli.md](cli.md) - Verified コミット（署名必須ルール対応）
