# ドライバ `conahcnuj`

issue（または PR）の解決を最後まで自律的に運ぶドライバです。実装は opencode の
コーディングエージェントが行い、ブランチ・Verified コミット・push・PR 作成・
レビュー依頼といった GitHub 側の操作はすべてドライバが行います。レビュースレッド
への返信だけはエージェント自身が行います（ドライバは代行コメントを投稿しません）。
**自動マージはしません**（マージは [workflows.md](workflows.md) の auto-merge 担当）。

## 使い方

```sh
conahcnuj <issue番号>     # issue から開始
conahcnuj <PR番号>        # PR なら自動で引き継いで再開
bash bin/conahcnuj.sh <番号>   # インストールせずリポジトリ内から直接実行する場合
```

- 対象リポジトリは `origin` remote から自動検出。remote が無い場合は
  `CONAHCNUJ_REPO=owner/repo` を指定
- 引数が PR と判明した時点で PR 再開モードに入る（MERGED は「対応不要」で
  exit 0、CLOSED は exit 1、OPEN は続行）
- 依存: `opencode`（PATH 上）、`git`、`curl`、`openssl`、設定済みの
  `gh-app/app.env` + 秘密鍵
- Windows + WSL 上で起動された場合、設定済みの `BASH_EXE`（Git Bash）へ
  自動でリローンチしてから実行する。リローンチ先は `exec` せず**子プロセス**
  として立ち上げて待ち合わせる: PowerShell からの Ctrl-C は先にこの WSL
  シェルへ届くため、親が生き残って SIGINT を子へ SIGTERM として転送し、
  Git Bash を止められる（中断が無視されて「効かない」ように見えなくする。#203）

## 流れ

1. issue を読み、最新のデフォルトブランチからフィーチャーブランチを作って
   opencode で実装。最初のモデルが失敗（rate limit 等）したら、同じ
   `sessionID` と作業ツリーを次のモデルへ引き継いで完了まで継続する
   （環境エラーで落ちた provider は切り分けられる）。rate limit
   （`Rate limit exceeded. Please try again later.`）は opencode が自前の
   再試行バックオフで数分待つため、ドライバが検知した時点でラウンドを打ち切り、
   再試行を待たずに次モデルへ移る（rate limit は環境エラーではないので provider
   は落とさない。#155）。モデル自体が deprecated / 削除 / 利用不可で落ちた場合は
   provider ではなくそのモデルだけを `gh-app/missing-models` に記録し、以後の
   ラウンドと次回実行ではラウンドを消費せずスキップする（#209）
2. エージェントが書いた `.commit-msg` で Verified コミットを作成し、PR を開く
3. 新規 PR は **リポジトリ owner を reviewer にアサイン**して先にレビュー依頼する
   （レビュアーは CI が green になるのを待たずにレビューを始められる。#233）。
   その後にレビュアー以外の制約（status checks・mergeable）をポーリングし、
   失敗していれば直す。制約が通った時点で正常終了（既に Approved なら
   「ready to merge」で終了）。再開した PR は merge 済みの可能性があるため、
   依頼の前に制約（PR の状態）を先に確認する
4. 再開実行で新しいレビュー意見（Comment / Request changes / 未解決スレッド）が
   あれば、モデルで対応して Verified コミット → owner へ再依頼 → 制約再確認 →
   終了。既知のレビュー意見は制約のポーリングを待たずに**先に**対応する
   （未解決スレッドが残る PR は、スレッドが片付くまで制約を満たせないので、
   先に待つと時間予算を無駄にするだけ。#219）。レビュースレッドへの返信は
   エージェント自身が行い、その返信は bot 著者として fingerprint から除外される
   ので自分の返信でループしない
5. 異常終了時（タイムアウト・全モデル失敗・想定外エラー等、非 0 で終わる場合）は、
   対象リポジトリへバグ報告 issue を自動作成する（終了コード・対象番号・ブランチ・
   HEAD・実行ログ末尾を含む）。ただし **Ctrl-C 等による利用者からの中断**
   （終了コード 130 / 143）はドライバのバグではなく、バグ報告を作成せずに
   正常終了する（#203）

ポーリングは GitHub のレートリミット（`Retry-After` / `X-RateLimit-Reset`）と
ジッター付きスリープで調整されます。

## エージェントとの契約

全ラウンド共通で、コーディングエージェントには次の一段落だけが伝えられます:

> This run takes the issue (or the pull request being resumed) to the owner's
> approval. Your part is the change in the working tree: implement it and run
> the repository's own validation. The driver names the branch and creates the
> commit, the push, the pull request and the review request once you are done.

契約に足さない代わりに、決定論的に収集できる情報は **データとして** 別枠で
同梱されます（`Collected context:` ブロック。指示ではなく材料を渡すので、
1 段落の契約には入れません）:

- issue / PR の本文（`Issue:` ブロック。もともとプロンプトに入っている）
- PR を再開するときの未解決レビュースレッド（解決済みは対象外）
- 作業ツリーの orientation ファイル（既定 `README.md` と `AGENTS.md`。
  `CONAHCNUJ_CONTEXT_FILES` で変更、空文字で送らない）

収集はブランチの checkout の直後に 1 度だけ行い、実行ログにも
`Collected context up front: ...` として何が同梱されたかを残します。

唯一の例外がレビュースレッドへの返信です。これはドライバが代行せず、
フィードバック対応ラウンドの追加コンテキストで各スレッドの comment id と返信
エンドポイント（`POST /repos/<owner>/<repo>/pulls/<n>/comments/<id>/replies`）を
添え、エージェント自身が返信します。返信は bot 著者のコメントとして
fingerprint から除外されるため、新規の reviewer 意見と誤認されません。

エージェントが決めるもの:

| ファイル | 内容 |
| --- | --- |
| `.commit-msg` | コミットメッセージ。**1 行・72 文字以内**。無い場合はドライバはコミットしない |
| `.branch-name` | フィーチャーブランチ名。無い場合はドライバが `conahcnuj/<番号>-<スラッグ>` で採番 |

- 作業ツリーに変更が無くて `.commit-msg` だけ書かれた場合は「no work」として
  次のモデルへ引き継ぎ、そのメッセージだけがブランチに乗る
- ブランチ名とコミットメッセージはエージェントの担当なので、ドライバ側で
  上書きしない

## 終了コード

| コード | 意味 |
| --- | --- |
| `0` | レビュー依頼の引き渡し（hand-off）完了 / ready to merge / PR は merge 済み |
| `1` | 異常終了（バグ報告 issue が作られる） |

引き渡しは依頼 API を 1 回だけ再試行し、PR を読み返して「本当に誰かに依頼されたか」
を確認します。読み返しが「誰も依頼されていない」と答えたときだけ失敗扱いにし、
読み返し自体が読めなかった場合は WARNING で終了します（#134 / #139）。

## 環境変数（ドライバ）

| 変数 | 既定 | 内容 |
| --- | --- | --- |
| `CONAHCNUJ_REPO` | origin から検出 | `owner/repo` |
| `CONAHCNUJ_MAX_SECONDS` | `259200`（72 h） | 1 実行全体の時間予算 |
| `CONAHCNUJ_HANDOFF_RETRY_SECONDS` | `15` | レビュー依頼リトライ前の待機（`0` で禁止） |
| `CONAHCNUJ_POLL_CONDITIONS_MIN` / `_MAX` | `15` / `300` | 制約ポーリングの間隔幅（秒・ジッター付き） |
| `CONAHCNUJ_COMMIT_MODEL` | 未設定 | コミット trailer（`Co-Authored-By: <値>`。プラグインが `provider (model/effort)` を設定する） |
| `CONAHCNUJ_OPENCODE_LOG_LEVEL` | `WARN` | opencode の `--log-level`（デバッグは `DEBUG`） |
| `CONAHCNUJ_OWN_WORKFLOWS` | `Issue auto-drive,Owner-approved auto-merge` | 制約チェックから除外する自 workflow（デッドロック防止） |
| `CONAHCNUJ_CONTEXT_FILES` | `README.md AGENTS.md` | プロンプトへ同梱する作業ツリーファイル（スペース区切り。空で無効） |
| `CONAHCNUJ_MISSING_MODELS_FILE` | `<gh-app>/missing-models` | 永久に使えないモデルの記録先（ラウンド前に読み、判明したモデルを追記） |
| `CONAHCNUJ_RATE_LIMIT_WATCH_SECONDS` | `1` | provider の rate limit を検知してラウンドを打ち切る監視間隔（秒） |
| `CONAHCNUJ_TEST_MODE` | `0` | `1` で offline テストモード（モック API テープ + モック opencode） |

全量は [environment.md](environment.md) を参照。

## ログ

opencode の JSON イベントは実行中に整形して stderr へ出て、そのままドライバの
実行ログになります（整形は省略をしない＝モデルが書いた行もコマンドが出した行も
全文）。表示量は `CONAHCNUJ_OPENCODE_LOG_LEVEL` で調整します。バグ報告 issue には
このログの末尾が添付されます。

この実行ログは週次で `weekly-self-improvement.yml` が解析し、次の週の改善 issue
（バグ報告・全モデル失敗・時間予算枯渇などの actionable な finding）として
ドライバへ引き渡します。解析対象のログ内容は
[self-improvement.md](self-improvement.md) を参照してください。

## 関連ページ

- [cli.md](cli.md) - ドライバが使う `api-commit.sh` / `setup-git.sh` の仕様
- [environment.md](environment.md) - 環境変数の全量（テスト用を含む）
- [workflows.md](workflows.md) - Actions 上での実行（issue-driver.yml）と auto-merge
