# 環境変数一覧

conahcnuj が読む環境変数の全量です。値の意味や設定ファイルとの関係は
[configuration.md](configuration.md)、使う場面は各ページを参照してください。

## GitHub App 設定

`gh-app/app.env` に書くキー（環境変数としても渡せるものがあります）。

| 変数 / キー | 既定 | 内容 |
| --- | --- | --- |
| `APP_ID` | -（必須） | GitHub App の ID |
| `INSTALLATION_ID` | -（必須） | インストール ID |
| `APP_SLUG` | -（必須） | App スラッグ（bot は `<slug>[bot]`） |
| `PRIVATE_KEY_PATH` | -（必須） | 秘密鍵 PEM のパス（`~` / WSL パス解決あり） |
| `BOT_USER_ID` | 自動解決 | bot ユーザー ID の手動上書き（シェル側のみ） |
| `GH_APP_API_BASE` | `https://api.github.com` | API ベース URL |
| `GH_APP_DIR` | `../gh-app` | ドライバが gh-app を探す場所 |

### `BASH_EXE` の解決順（消費側ごとに違う）

| 消費側 | 優先順位 |
| --- | --- |
| シェルスクリプト（`setup-git.sh` 等） | `app.env` の値（プレースホルダ含む）→ 未定義なら `C:/Program Files/Git/bin/bash.exe` |
| ドライバ | 環境変数 `BASH_EXE` → `app.env`（プレースホルダは未設定扱い）→ `C:/Program Files/Git/bin/bash.exe` |
| opencode プラグイン | `app.env` の値（不正値でも尊重）→ Windows 既定 `C:/Program Files/Git/bin/bash.exe`、それ以外は `bash` |

## ドライバ実行時

| 変数 | 既定 | 内容 |
| --- | --- | --- |
| `CONAHCNUJ_REPO` | origin から検出 | `owner/repo` |
| `CONAHCNUJ_MAX_SECONDS` | `259200`（72 h） | 1 実行の時間予算 |
| `CONAHCNUJ_HANDOFF_RETRY_SECONDS` | `15` | レビュー依頼リトライ前の待機秒（`0` で禁止） |
| `CONAHCNUJ_POLL_CONDITIONS_MIN` | `15` | 制約ポーリングの最短間隔（秒） |
| `CONAHCNUJ_POLL_CONDITIONS_MAX` | `300` | 制約ポーリングの最長間隔（秒） |
| `CONAHCNUJ_COMMIT_MODEL` | 未設定 | コミット trailer（`Co-Authored-By: <値>`。プラグインが `provider (model/effort)` を設定）。未設定なら trailer なし |
| `CONAHCNUJ_OPENCODE_LOG_LEVEL` | `WARN` | opencode の `--log-level` |
| `CONAHCNUJ_OWN_WORKFLOWS` | `Issue auto-drive,Owner-approved auto-merge` | 制約チェックから除外する自 workflow 名（カンマ区切り） |
| `CONAHCNUJ_CONTEXT_FILES` | `README.md AGENTS.md` | 最初のプロンプトへ同梱する作業ツリーファイル（スペース区切り）。空文字で同梱を無効化 |
| `CONAHCNUJ_BUG_REPORT_CATEGORY` | `Bug report` | バグ報告 discussion を置くカテゴリ名（`discussion-driver.yml` のフィルタと同一値） |
| `CONAHCNUJ_TEST_MODE` | `0` | `1` で offline テストモード |

## ドライバ ↔ プラグイン連携（自動設定）

| 変数 | 方向 | 内容 |
| --- | --- | --- |
| `CONAHCNUJ_SESSION_MODEL` | ドライバ → プラグイン | そのラウンドで選んだ `provider/model`。副作用モデルのラベル化を防ぐ |
| `CONAHCNUJ_MODEL_LABEL_FILE` | ドライバ → プラグイン | モデルラベルを書き込む先（temp 配下に限定） |

## Docker ラッパー（`docker-run.sh`）

| 変数 | 既定 | 内容 |
| --- | --- | --- |
| `CONAHCNUJ_IMAGE` | `conahcnuj-runner` | イメージタグ |
| `CONAHCNUJ_TARGET` | カレントディレクトリ | 対象リポジトリ（`/work` へマウント） |
| `CONAHCNUJ_APP_ENV` | `<このリポジトリ>/gh-app/app.env` | ホスト側 `app.env` |
| `CONAHCNUJ_BUILD` | `0` | `1` でイメージを強制リビルド |
| `CONAHCNUJ_DAEMON` | `0` | `1` で detached 実行（`docker logs` で追える） |
| `CONAHCNUJ_NAME` | `conahcnuj-<epoch>` | daemon 時のコンテナ名 |
| `OPENCODE_CONFIG_DIR` | `~/.config/opencode` | opencode 設定のホスト側パス（読み込み） |
| `OPENCODE_DATA_DIR` | `~/.local/share/opencode` | opencode データのホスト側パス（読み込み） |

`CONAHCNUJ_REPO` / `CONAHCNUJ_MAX_SECONDS` / `CONAHCNUJ_POLL_*` はそのまま
コンテナへ渡されます。詳細は [installation.md](installation.md)。

## GitHub Actions 内

| 変数 / secret | 使う workflow | 内容 |
| --- | --- | --- |
| `secrets.APP_ID` / `INSTALLATION_ID` / `APP_SLUG` / `PRIVATE_KEY` | issue-driver | App 認証情報（PEM は `$RUNNER_TEMP` へ書き出し） |
| `CONAHCNUJ_INPUT` | issue-driver | issue / PR 番号（workflow 側の受け渡し用） |
| `CONAHCNUJ_MAX_SECONDS=3540` | issue-driver | `timeout-minutes: 60` より前に自己終了するための予算 |
| `OPENCODE_DISABLE_AUTOUPDATE` | issue-driver / e2e | opencode の自動更新を停止 |
| `IGNORED_WORKFLOWS` | owner-approved-auto-merge | マージ待ちチェックから除外する workflow 名（既定 `Issue auto-drive`） |

## テスト専用（本番では触らない）

| 変数 | 内容 |
| --- | --- |
| `GH_API_TEST_MODE=1` | `lib/gh-api.sh` をオフライン化。API 1 コールごとに stdin から 1 行のモック応答を読む |
| `CONAHCNUJ_IMPORT=1` | `bin/conahcnuj.sh` を `main` 実行せずに source する（単体テスト用） |
| `OPENCODE_TEST_MODE=1` | `opencode` の代わりにモックを使う |
| `MOCK_OPENCODE_MODELS` | モックのモデル一覧（`provider/model` を 1 行ずつ） |
| `MOCK_OPENCODE_ERROR` | 指定モデルを環境エラーで失敗させる |
| `MOCK_OPENCODE_ENV_ERROR` | 各ラウンドを環境エラーで終了させる（`conahcnuj-env-failure` 再現） |
| `MOCK_OPENCODE_MESSAGE_ONLY` | 作業ツリー無変更 + `.commit-msg` のみのラウンドを再現 |
| `MOCK_OPENCODE_NOOP` | 指定モデルを no-op（実装を省略した振る舞い）にする |
| `MOCK_OPENCODE_SESSION_ID` | モックが返す `sessionID` |

## 内部変数（実装詳細・上書きしない）

ドライバとライブラリが内部状態として扱う変数です。ユーザー設定ではありません。

`OPENCODE_SESSION_ID` / `OPENCODE_LAST_MODEL` / `OPENCODE_USED_MODELS` /
`OPENCODE_HANDOFFS` / `OPENCODE_ROUND_ENVIRONMENT`（ラウンド成否の分類）/
`CONAHCNUJ_RUN_TIMEOUT_SECONDS`（単発ラウンドのタイムアウト）/
`OPENCODE_LIB_DIR` / `OPENCODE_RENDER_SH`（ライブラリの場所）/
`GH_API_LAST_HTTP_CODE`（最後の HTTP ステータス）/
`PR_BODY_SYNCED_FILE` / `PR_CONTINUATION_COMMENTED_FILE`（プロセス内マーカー）/
`OPENCODE_ARGS_FILE`（テスト用モックが引数を受け取る経路）。

## 関連ページ

- [configuration.md](configuration.md) - `app.env` とキャッシュ
- [driver.md](driver.md) - ドライバの使い方
- [workflows.md](workflows.md) - Actions 上での変数の渡し方
