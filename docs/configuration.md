# 設定（`gh-app/app.env`）

conahcnuj の設定は dotenv 風のテキストファイル 1 枚で完結します。

## ファイルの場所と fallback

| 優先 | パス | 用途 |
| --- | --- | --- |
| 1 | `gh-app/app.env` | 実設定（`.gitignore` 済み・リポジトリへコミットしない） |
| 2 | `gh-app/app.env.example` | テンプレート。`app.env` が無いとき全スクリプトが fallback として読む（fresh clone / CI） |

`app.env.example` はプレースホルダ値（`<your-app-id>` 等）のままコミットされて
います。プレースホルダ値は「未設定」として扱われ、実 API の呼び出しには失敗します
（エラーになるだけで、勝手に別の値に置き換わることはありません）。

書式は `KEY="VALUE"` の 1 行 1 キー。コメントは `#` 行。opencode プラグイン側の
パーサは引用符を除去し、`${HOME}` をホームへ展開し、`UPPER_SNAKE` のキーだけを
受け付けます（それ以外の行は無視）。

## キー

| キー | 必須 | 内容 |
| --- | --- | --- |
| `APP_ID` | ○ | GitHub App の ID。JWT の `iss` に入る値 |
| `INSTALLATION_ID` | ○ | App のインストール ID。トークン交換先 `/app/installations/{id}/access_tokens` |
| `APP_SLUG` | ○ | App のスラッグ。bot アカウントは `<slug>[bot]`、git の `user.name` / `user.email` と bot ID の自動解決に使う |
| `PRIVATE_KEY_PATH` | ○ | App の秘密鍵（PEM）のパス。`~` 展開、WSL の `/mnt/<ドライブ>/...` は Git Bash 向けに `/<ドライブ>/...` へも解決 |
| `BASH_EXE` | ○（Windows） | bash の起動経路。Windows の素の `bash` は WSL に解決されるため Git for Windows の実体を指定する（既定 `C:/Program Files/Git/bin/bash.exe`） |
| `BOT_USER_ID` | - | bot アカウントのユーザー ID の手動上書き。無ければ自動解決（下記） |

`APP_ID` は bot アカウントの ID の代替になりません（App 自身の ID のため）。
bot ID の解決順は [cli.md](cli.md#bot-user-idsh) を参照。

## 補助的な環境変数

| 変数 | 既定 | 内容 |
| --- | --- | --- |
| `GH_APP_API_BASE` | `https://api.github.com` | REST / GraphQL のベース URL（シェル側・ドライバ用。**プラグインは常に `api.github.com` を叩く**ため Enterprise では未対応） |
| `GH_APP_DIR` | ドライバの `../gh-app` | ドライバが gh-app を探す場所の上書き |
| `BASH_EXE` | 下記参照 | 環境変数が app.env より優先。各消費側の既定は [environment.md](environment.md) |

## キャッシュファイル

いずれも `gh-app/` 配下・ `.gitignore` 済みで、削除すれば次回取得し直します。

| ファイル | 形式 | 内容 |
| --- | --- | --- |
| `token.cache` | `有効期限(UNIX秒)\|トークン` | インストールトークン。有効期限は `expires_at - 600` 秒。シェル側（`get-token.sh`）と opencode プラグインが**同じファイルを共有** |
| `bot-id.cache` | 数字のみ | bot アカウントのユーザー ID。不変のため無期限 |

トークンの有効期間は約 1 時間ですが、キャッシュは期限の 10 分前までしか使いません
（プラグインはさらに 50 分のメモリ TTL を併用します）。

## セキュリティ上のルール

- 秘密鍵（`.pem`）をリポジトリへコミットしない。
- `app.env` / `token.cache` / `bot-id.cache` はコミットしない（`gitignore` 済み）。
- 秘密鍵そのものはネットワークへ送信されません。送るのはローカルで署名した
  短命な JWT だけです。
- CI 上では秘密鍵は repo secrets からランナーの外（`$RUNNER_TEMP`）へ書き出され、
  作業ツリーの外に置かれます。

## 関連ページ

- [cli.md](cli.md) - 各スクリプトがこの設定をどう使うか
- [plugin.md](plugin.md) - プラグイン側の読み込み規則
- [installation.md](installation.md) - `app.env` を作るタイミングを含む配置手順
