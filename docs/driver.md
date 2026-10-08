# ドライバ `conahcnuj`

issue（または PR）の解決を最後まで自律的に運ぶドライバです。実装は opencode の
コーディングエージェントが行い、ブランチ・Verified コミット・push・PR 作成・
レビュー依頼といった GitHub 側の操作はすべてドライバが行います。**自動マージは
しません**（マージは [workflows.md](workflows.md) の auto-merge 担当）。

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
  自動でリローンチしてから実行する

## 流れ

1. issue を読み、最新のデフォルトブランチからフィーチャーブランチを作って
   opencode で実装。最初のモデルが失敗（rate limit 等）したら、同じ
   `sessionID` と作業ツリーを次のモデルへ引き継えて完了まで継続する
   （環境エラーで落ちた provider は切り分けられる）
2. エージェントが書いた `.commit-msg` で Verified コミットを作成し、PR を開く
3. レビュアー以外の制約（status checks・mergeable）が通るまでポーリングして、
   **リポジトリ owner を reviewer にアサイン**してレビュー依頼 → ここで正常終了
   （既に Approved なら「ready to merge」で終了）
4. 再開実行で新しいレビュー意見（Comment / Request changes / 未解決スレッド）が
   あれば、モデルで対応して Verified コミット → 制約再確認 → PR 返信 →
   owner へ再依頼して終了
5. 異常終了時（タイムアウト・全モデル失敗・想定外エラー等、非 0 で終わる場合）は、
   対象リポジトリへバグ報告 issue を自動作成する（終了コード・対象番号・ブランチ・
   HEAD・実行ログ末尾を含む）

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
| `CONAHCNUJ_TEST_MODE` | `0` | `1` で offline テストモード（モック API テープ + モック opencode） |

全量は [environment.md](environment.md) を参照。

## ログ

opencode の JSON イベントは実行中に整形して stderr へ出て、そのままドライバの
実行ログになります（整形は省略をしない＝モデルが書いた行もコマンドが出した行も
全文）。表示量は `CONAHCNUJ_OPENCODE_LOG_LEVEL` で調整します。バグ報告 issue には
このログの末尾が添付されます。

## 関連ページ

- [cli.md](cli.md) - ドライバが使う `api-commit.sh` / `setup-git.sh` の仕様
- [environment.md](environment.md) - 環境変数の全量（テスト用を含む）
- [workflows.md](workflows.md) - Actions 上での実行（issue-driver.yml）と auto-merge
