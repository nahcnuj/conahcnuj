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
- ドライバの整形ログ（`lib/opencode-render.sh`）は truncate しない。行数・桁数で省略せず、モデルが書いた行もコマンドが出力した行も全文が出る（`CONAHCNUJ_RENDER_MAX_LINES` / `CONAHCNUJ_RENDER_MAX_COLS` に相当する省略は行わない。両変数は廃止済み）。このログは run の唯一の記録で、異常終了時はその一部がバグ報告に載るため、省略は「モデルがそう言わなかったこと」と区別できない穴になる。
- コーディングエージェントへのプロンプトに指示を積み増さない。`opencode_agent_contract` が伝えるのは「この issue／PR を owner の Approve まで導く・エージェントの担当は作業ツリーの変更、GitHub 側の操作はドライバ」だけにする（禁止コマンドの一覧や「これは成果物ではない」「やっても no work」といった注意は書かない）。実際に禁止と注意を並べた長い contract を入れたとき、エージェントがそれを任務と誤解してコミットメッセージだけ出して終わるので、_owner のレビューで「エージェントの仕事を邪魔している」と弾かれる_（`tests/opencode.sh` がプロンプトに禁止コマンド列と「counts as no work」が現れないことを検証する）。

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
| `gh-app/tests/` | 観点別テスト（`get-token-cache` / `git-credential-helper` / `api-commit-args` / `api-commit-dryrun` / `api-commit-trailer` / `bot-user-id`） | いずれも秘密鍵・ネットワーク不要。`run.sh` から実行 |
| `plugins/gh-app-token.ts` | opencode プラグイン。`shell.env` で `GH_TOKEN` と `GIT_CONFIG_*`（bot 名義 + `alias.vc`。配列生成）注入、`experimental.chat.system.transform` でコミット規則（`git vc` を使う）をシステムプロンプトへ常時注入、`tool.execute.before` で `git commit` と `api-commit.sh` の直接実行をブロックして `git vc` へ誘導（`&&` や `bash -c` 越しも検知。引用符・前方代入・シェルラッパを鑑みたうえでコマンドワードだけで判定するため、`cat gh-app/api-commit.sh` は通す）。セッションのモデル表示名と variant を `CONAHCNUJ_COMMIT_MODEL` に入れる | `BASH_EXE` で get-token.sh を実行。`loadAppEnv()` で app.env をパース。`BOT_USER_ID` 未設定時は `bot-user-id.sh` で自動解決。`CONAHCNUJ_SESSION_MODEL`（`provider/model`）が設定されているときはそのモデルだけを記録する |
| `opencode/AGENTS.md` | opencode のグローバルルール（`git commit` ではなく `git vc` でコミット）。`install.ps1` が `<!-- conahcnuj:begin -->` / `end` の管理ブロックとして `~/.config/opencode/AGENTS.md` へ配置し、既存ファイルは他の内容を保ったまま追記・更新する | グローバル AGENTS.md は全リポジトリへ効くため、nahcnuj の各リポジトリに同じ指示を個別に書かなくてよい。管理ブロックの外は保持される |
| `test/smoke.sh` / `smoke-run.js` | プラグインの runtime smoke テスト（`install.ps1`→読込→env 契約・システムプロンプト規則・commit/api-commit.sh 誘導を検証。`plugins/` 外に置くのは opencode の自動ロード対象外にするため） | node/npm と pwsh が必要。CI の `plugin-smoke` で実行 |
| `test/unit.sh` / `unit-run.js` | プラグイン内部のユニットテスト（`git vc` 誘導のコマンド判定・`app.env` / token cache の解析・モデルラベル・フック配線）。`unit.sh` は内部関数を再エクスポートした test ビルドを `test/.unit/` へコンパイルして使う | node/npm のみ（pwsh 不要）。CI の `plugin-unit` で実行。**プラグインの export は `GhAppTokenPlugin` だけ**（opencode のローダは全 export をプラグイン扱いする） |
| `plugins/lib/gh-app-commit.ts`・`gh-app-commit.test.ts` | `git commit` / `api-commit.sh` 直接実行のコマンド判定モジュールとそのユニットテスト（`test/unit.sh` が実行） | opencode は `plugins/*.ts` の**トップレベルだけ**を自動ロードし全 export をプラグイン扱いするため、ヘルパーは `plugins/lib/` に置く（`install.ps1` が `<Destination>/plugins/lib/` へ配備し、旧配置の `plugins/gh-app-commit.ts` は削除）。CI の `install-test` は plugins 直下が `gh-app-token.ts` のみであることを検証 |
| `plugins/package.json`・`package-lock.json`・`tsconfig.json` | 型チェック基盤（`@types/node` と `@opencode-ai/plugin` は plugins/package.json＋lock から取得） | CI の `lint-ts` で実行。`node_modules/` は gitignore |
| `bin/conahcnuj.sh` | issue駆動自律開発ドライバ（issue→フィーチャーブランチ→PR→owner を reviewer にアサインしてレビュー依頼＝終了。既に Approved なら ready to merge で終了） | `lib/`・`tests/`・`test.sh` とセット。実行は `conahcnuj <issue番号>`（PR番号なら自動で再開）。ブランチ名・コミットメッセージはコーディングエージェントが決める（`.branch-name` / `.commit-msg`）。環境変数上書き・offline テストモードはヘッダーコメント参照。異常終了時はバグ報告 issue を対象リポジトリへ自動作成（`gh_api_create_issue`）。ブランチの fetch に失敗すると作業ツリーが古いまま進み、既コミットの実装を消しかねないため、`checkout_branch_head` はその場で停止する。`request_review_from_owner` は依頼 API の失敗を鵜呑みにせず、まず `request_review_with_retry` で 1 回だけ再試行し（同じ reviewer を二重登録しても GitHub 側に要求は残らないので冪等）、それでも失敗したら `gh_api_requested_reviewers` で PR を読み返す（GitHub が記録した後の通信エラーは拒否と区別できず、そのままだと完了した run が exit 1 でバグ報告される。#134 / #139）。**読み返しが「誰も依頼されていない」と答えたときだけ** run を失敗させ、読み返し自体が失敗した場合は PR は完成済みなので WARNING で終了する（`REVIEW_HANDOFF_CONFIRMED` が false のときは `log_review_handoff` が「依頼を確認できなかった」文言を出す。「読めなかった」を「誰も聞いていません」と読むと検証不能な引き渡しをバグ報告に 바꾸てしまう） |
| `lib/` | ドライバ用ライブラリ（`gh-api.sh` / `opencode.sh` / `opencode-render.sh` / `rate-limit.sh`） | `opencode.sh` は失敗したモデルから `sessionID` と作業ツリーを次モデルへ引き継ぐ。プロンプト（`opencode_agent_contract` が全ラウンド共通の契約）は 1 段落だけで、「この issue／PR を owner の Approve まで導く・エージェントの担当は作業ツリーの変更、ブランチ名・コミット・push・PR の作成（タイトルと本文）・レビュー依頼はドライバ」を伝えるだけに留める。`opencode-render.sh` は opencode の JSON イベント列を実行中に整形して stderr へ出す（`jq`/node 不要・純 awk）。同じ part id の同じ内容が再送された場合（セッション再開・イベントストリーム再接続）は 1 度だけ表示する。出力はドライバの実行ログに入るので、異常終了時のバグ報告にもモデルの行動が残る。表示量は `CONAHCNUJ_OPENCODE_LOG_LEVEL`（既定 `WARN`。`--print-logs` の既定 INFO はモデルごとに 30 行近い起動ログを出す）と `CONAHCNUJ_RENDER_MAX_LINES` / `CONAHCNUJ_RENDER_MAX_COLS`（既定 200 行 / 400 桁。省略分は必ず明示される）で調整する。`gh-api.sh` は `GH_API_TEST_MODE=1` で stdin からモック応答を 1 コール 1 行読み、ネットワーク I/O をしない。`gh_api_call` の HTTP ステータスは curl のヘッダダンプの**最後の**ステータス行から読む（複数ブロック時に 1 行目を読むと応答を取り違える）もので、2xx 以外はメソッド・URL・ステータス・レスポンス本文を stderr に出す（呼び出し側は stdout を捨てるため、理由がそこしか残らない）。REST の JSON は GraphQL と違って整形済み（`"login": "x"` のようにコロン後に空白）で返るので、REST 応答を絞る正規表現は空白を許容すること（コンパクトな綴りだけを前提にしたモックテープでは通っていても実応答では 1 件も見つからず、`gh_api_requested_reviewers` の読み戻しが「誰も依頼されていない」と答えて、PR 側は依頼済みでもレビュー引き渡しが失敗扱いになる #136）。`gh_api_fetch_pr_conditions` は `statusCheckRollup.contexts` を集計し、ドライバ自身の workflow（既定 `Issue auto-drive,Owner-approved auto-merge`。`CONAHCNUJ_OWN_WORKFLOWS` で変更可）の check を制約から除外する。自分の run と merge 待ちの job を待ち続けるデッドロックと、キャンセル済み run を「直せない制約」とみなすループを防ぐため。出力は `checks|mergeable|mergeStateStatus|pr_state` で、poll 中に merge 済みの PR は終了処理へ移る |
| `tests/`・`test.sh` | ドライバの offline モックテスト（モック API tape ＋ モック opencode でフロー検証。`auto-merge-outstanding-checks.sh` は workflow 内の jq を抽出して実 payload で検証する。jq 不在時は skip） | 秘密鍵・ネットワーク不要。CI の `mock-test` で `test.sh` を実行。`conahcnuj-branch-head.sh` はローカルの bare リポジトリを origin にして、fetch 失敗時に古い head で続行せず停止することを検証。`conahcnuj-message-only.sh` は `.commit-msg` だけ書いたモデル（作業ツリーは無変更）を no work として次モデルへ引き継ぎ、その変更だけがブランチに乗ることを検証（`MOCK_OPENCODE_MESSAGE_ONLY` で再現可） |
| `tests/conahcnuj-env-failure.sh` | provider ごと環境エラーで落ちたラウンドのスキップ・診断・バグ報告文言と、環境エラーでない失敗では provider を落とさないことを検証 | `MOCK_OPENCODE_ENV_ERROR` で再現可。判定は `lib/opencode.sh` の `opencode_round_is_environment`（失敗ラウンドの生 JSON イベント行を grep。テキストイベントは対象外、status が 0 以外のときだけ分類）。全ラウンドが環境エラーだったときの `ENVIRONMENT_DOWN=1` とバグ報告の書き出し・締めの文言切替は `bin/conahcnuj.sh`（#149） |
| `install.ps1` | `~/.config/opencode`（または `-Destination`）へ配置。加えて `conahcnuj` バイナリ（既定 `~/.local/bin`）と bin 側 `gh-app/`・`lib/` を配置 | gh-app は**2 箇所**へ配備（opencode 設定用とドライバ用）。実 `app.env` があればそれを、無ければ example から作成 |
| `test/install-agents-md.ps1` | `Install-GlobalAgentsMd`（グローバル AGENTS.md への管理ブロック merge）のテスト。実物の `install.ps1` を一時 Destination＋InstallPath で実行し、新規作成・個人ルール保持・再実行の冪等性・未終端ブロックの書換・end マーカー後の個人ルール生存を検証 | pwsh のみ。CI の `install-test` が実行。
| `Dockerfile` | conahcnuj 実行用の隔離イメージ（opencode・git・curl・openssl とドライバを同梱） | 秘密鍵・`app.env` は焼き込まない。`ENTRYPOINT` はドライバ |
| `docker-run.sh` | 上記イメージでドライバを実行するラッパー（対象リポジトリを `/work` へマウント、コンテナ用 `app.env` を生成し秘密鍵を読み取り専用マウント） | テストではなく**実走行**用（実キー・ネットワーク・opencode 設定が必要） |
| `.github/workflows/ci.yml` | 読み取り専用 CI（`permissions: contents: read`） | `actions/checkout` は full-length SHA でピン留め（リポジトリの Actions ポリシー準拠）。`lint-bash` / `mock-test` / `plugin-unit` / `plugin-smoke` は Ubuntu + Windows、`lint-ts` / `e2e-opencode` は Ubuntu、`lint-ps` / `install-test` は Windows のみ |
| `.github/actions/install-opencode/action.yml` | opencode を最新リリースで導入する composite action（authenticated リリース検索＋PATH 設定） | `ci.yml` と `issue-driver.yml` の両方が `uses: ./.github/actions/install-opencode` で共有。未認証の `api.github.com` は共有ランナーでレート制限に当たりやすいためトークン付きで解決する |
| `.github/workflows/issue-driver.yml` | issue が open / reopen されたらドライバで自動対応を試みる（issue→PR まで。失敗時はバグ報告 issue） | タイムアウトは Actions 側で制御（`timeout-minutes: 60`）。`CONAHCNUJ_MAX_SECONDS=3540` でドライバが先に自己終了しバグ報告を残す。repo secrets `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` / `PRIVATE_KEY`（PEM）が必要。bot 名義の issue（`<slug>[bot]` 含む）は再帰防止のため `user.type` でスキップ（job レベルの `if` は `secrets` を参照できないため）。`GITHUB_TOKEN` は `contents: read` のみ（書き込みは全て App トークン） |
| `.github/workflows/auto-merge.yml` | owner の PR 承認時に auto-merge を有効化 | 承認した head SHA と一致する場合だけ merge commit を要求。green 済みなら即時マージ。書き込みには `GITHUB_TOKEN` を使用 |
| `.github/workflows/owner-approved-auto-merge.yml` | owner 承認後の auto-merge を `workflow_call` で再利用する workflow | 利用側は `pull_request_review` を購読し、必要な権限を渡す。secret は不要。GraphQL の `statusCheckRollup` を `databaseId`（自身の run）と workflow 名（既定 `Issue auto-drive`。`IGNORED_WORKFLOWS` で変更可）で除外し、CI だけが merge をブロックする。自身を待つとドライバとデッドロックするため。check 一覧が読めない（rollup が `null` / 次のページあり）場合は merge しない |

## ローカル検証手順

```bash
# 構文チェック（Ubuntu で確認）
bash -n gh-app/*.sh gh-app/tests/*.sh bin/*.sh lib/*.sh tests/*.sh test.sh
shellcheck -x gh-app/*.sh gh-app/tests/*.sh bin/*.sh lib/*.sh tests/*.sh test.sh   # -x で app.env.example を追従（チェックは無効化しない）

# プラグイン型チェック（@types/node は plugins/package.json＋lock から取得）
(cd plugins && npm ci --no-audit --no-fund && ./node_modules/.bin/tsc -p ../plugins --noEmit)

# プラグインのテスト（node/npm のみ。smoke は pwsh も使う）
bash test/unit.sh   # 内部ロジックのユニットテスト
bash test/smoke.sh  # install.ps1 → 読込 → フック契約の runtime テスト

# offline モックテスト（秘密鍵・ネットワーク不要）
bash gh-app/tests/run.sh
bash test.sh   # ドライバの offline テスト（bin/・lib/・tests/）

# install.ps1 のグローバル AGENTS.md merge テスト（pwsh のみ）
pwsh -NoProfile -File test/install-agents-md.ps1

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
- **`git commit` は使わない**（プラグインが `commit.gpgsign=false` を注入するため unsigned になり、「Commits must have verified signatures」でブロックされる。`true` に変えても署名鍵が無いため `git commit` 自体が失敗する。opencode 上ではプラグインの `tool.execute.before` が `git commit` と `api-commit.sh` の直接実行を検知してエラーにし、`git vc` へ誘導する）。Verified コミットは `git vc` だけで作成する：
  ```bash
  git vc -m "message"              # staged の内容をコミット（git commit 相当）。どのリポジトリでも動く
  git vc -m "message" -a           # tracked の作業ツリー変更をコミット（git commit -a 相当）
  ```
  `CONAHCNUJ_COMMIT_MODEL` があれば `api-commit.sh` が本文へ `Model: <ラベル>` trailer を足す。OpenCode 上の `git vc` はプラグインがラベルを入れる。未設定なら trailer は付かない。
  `git vc` はプラグインが注入する git alias（組み込みの上書きは不可のため新規名 `vc`）。**エージェントはコミット時に自然と `git vc` を選ぶこと**（`git commit` の代わりに `git vc` を使う）。
  owner/repo/branch は `git remote` と現在ブランチから自動検出される。
  `api-commit.sh` は `git vc` の実装詳細であり、**エージェントは直接実行しない**（`git vc` が正しい owner/repo/branch と App 名義を引き受ける）。下記の仕様は保守者向け。
- `gh-app/api-commit.sh` の仕様:
  - 1 実行でブランチ先端に Verified コミットを **1 件だけ**作る（author は bot、committer は GitHub・署名付き）。`git add -A`＋`git commit -m` と収集内容は同じだが、作成場所（GitHub サーバー側）が違うため署名付きになる。
  - 無印は staged の内容を index（`git show :path`）から読む（`git commit` 相当。新規ファイルは `git add` でステージする）。`-a` は tracked の作業ツリー変更を読む（untracked 除外。`git commit -a` 相当。削除・リネーム対応）。
  - 注意: `-a` はコミット操作であり、ステージングでは無い。収集と Verified コミット作成を1実行で行う（中間ステージは作らない）。
  - `--delete <path>`（明示削除）、`--create-branch`（デフォルトブランチ起点で ref を作成。新規ブランチ用）、`--dry-run`（API を呼ばず収集結果のみ表示。token/network 不要）。
  - 既存ブランチへの追記のみ。履歴の書き換え・force-push はしない。unsigned コミットが既にあるブランチは、先に `git fetch` → `git reset --hard` で作り直してから使うこと。
- `git push` で unsigned コミットを送らない。`api-commit.sh` はコミットを直接リモートブランチに作成するため push 不要。ローカル同期は `git fetch origin` → `git reset --hard origin/<branch>`。