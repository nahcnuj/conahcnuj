# opencode プラグイン（`gh-app-token.ts`）

opencode のセッションが起動するシェルに **GitHub App の名義**を注入し、
unsigned コミットを塞ぐプラグインです。ファイルは `plugins/gh-app-token.ts`、
`install.ps1` により opencode の設定ディレクトリ（既定
`~/.config/opencode/plugins/`）へ配置されます。

- **プラグインは opencode の起動時にロードされます。変更後は opencode を再起動**。
- 設定は `gh-app/app.env` を読みます（[configuration.md](configuration.md)）。
  必須は `APP_SLUG` のみ。トークン発行には `APP_ID` / `INSTALLATION_ID` /
  `PRIVATE_KEY_PATH` が必要で、それらは実際にトークンを取るときに検証されます。

## フック

### `shell.env` - シェルへの注入

セッションが起動するすべてのシェルに次を注入します。

| 変数 | 内容 |
| --- | --- |
| `GH_TOKEN` | インストールトークン（**ベストエフォート**。取得失敗してもシェル起動は止めない） |
| `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` | 下表の git 設定 5 件 |
| `CONAHCNUJ_COMMIT_MODEL` | 既に設定されていなければ、セッションのモデル表示名（ラベル） |

| git 設定 | 値 |
| --- | --- |
| `user.name` | `<APP_SLUG>[bot]` |
| `user.email` | `<botUserId>+<APP_SLUG>[bot]@users.noreply.github.com` |
| `credential.helper` | `!"<BASH_EXE>" "<gh-app>/git-credential-helper.sh"` |
| `commit.gpgsign` | `false` |
| `alias.vc` | `!"<BASH_EXE>" "<gh-app>/api-commit.sh"`（[git vc](#git-vc)） |

### `experimental.chat.system.transform` - システムプロンプトへの規則注入

全セッションのシステムプロンプトへ 1 行ずつの規則を追加します（重複しません）。

- **`git vc` 規則**: コミットは `git vc` で行い、`git commit` を使わない。
  `gh-app/api-commit.sh` を直接実行せず、`gh-app/` 配下を編集しない。
- **GitHub 認証規則**: `GH_TOKEN` は各シェルへ注入済みなので `gh` をそのまま
  使えばよい。エージェントが `GH_TOKEN` を自分で export したり
  `gh-app/get-token.sh` を実行してトークンを取り直したりしない。
- **シェル規則**: 実行環境の OS・シェルに応じた規則（null デバイス、
  行継続、文の区切り文字など）。Windows の PowerShell では `&&` は文の
  区切り文字として使えず `The token '&&' is not a valid statement separator
  in this version.` になるため、`&&` を使わず `;` で連結するかコマンドを
  別々に実行する。

### `tool.execute.before` - `git commit` のブロック

bash ツールが `git commit`（`git.exe commit`、`-C <dir> commit` も含む）を呼ぼうと
すると、`Commits must have verified signatures` でブロックされる旨と代替手段
（`git vc -m "<メッセージ>" [-a]`）を示すエラーで失敗させます。他の git サブコマンドは
通します。

### `chat.message` / `chat.params` - モデルラベルの記録

セッションのモデルの表示名と effort（variant）を組み合わせた 1 行ラベル
（例: `Grok 4.7 (medium)`）を記録し、`CONAHCNUJ_MODEL_LABEL_FILE` が設定されていれば
そのファイルへ 1 行で書き込みます（パスはシステムの temp ディレクトリ配下に
限定）。`CONAHCNUJ_SESSION_MODEL` が設定されているときは、そのモデル
（`provider/model`）だけを記録します。ドライバはこのファイルを
`provider (model/effort)`（例: `xai (grok-4.7/medium)`）の形で、そのまま
`CONAHCNUJ_COMMIT_MODEL` として [api-commit.sh](cli.md#api-commitsh) に渡します。

## `git vc`

プラグインが注入する git alias（verified-commit）。実体は
[api-commit.sh](cli.md#api-commitsh) です。

```sh
git vc -m "<メッセージ>"        # staged の Verified コミット
git vc -m "<メッセージ>" -a     # tracked 変更を Verified コミット
```

owner/repo/branch は自動検出なのでどのリポジトリでも動きます。組み込みの
`git commit` を上書きできないため、代わりにこの新規 alias を使います。

## トークンの扱い

- シェル側 [get-token.sh](cli.md#get-tokensh) と**同じ `gh-app/token.cache` を共有**。
  キャッシュが有効ならネットワーク不要
- メモリ内では 50 分の TTL を持つ。期限切れ・無効なら RS256 署名の JWT
  （`exp` = 現在 + 540 秒）で `POST /app/installations/{id}/access_tokens` を叩き直す
- 秘密鍵はローカルで署名するためにだけ読み、ネットワークへは送らない

## bot ID の解決

プラグインのロード時に `<APP_SLUG>[bot]` のユーザー ID を解決します:

1. `gh-app/bot-id.cache`（不変・無期限）
2. 公開 API `GET /users/<slug>%5Bbot%5D`（認証不要。slug は
   `^[A-Za-z0-9-]+$` のみ許可）→ 成功したらキャッシュへ

どちらも不可だとプラグインのロードが失敗します。オフラインでロードするなら、
配置済みの `<配置先>/gh-app/bot-id.cache` に ID（数字だけ）を書いておく。
なお `BOT_USER_ID` の手動上書きはシェル側スクリプト
（[bot-user-id.sh](cli.md#bot-user-idsh)）用で、プラグインは読みません。

## エラー

| 状況 | 挙動 |
| --- | --- |
| `APP_SLUG` 未設定 | プラグインロード時に `Missing required gh-app config: APP_SLUG` で失敗 |
| トークンキー不足 | トークン取得時にエラー。`GH_TOKEN` は注入されない（git identity は注入される） |
| `INSTALLATION_ID` が非数字 | URL への混入防止のため即エラー |
| トークン形式不正 | キャッシュへ書かずエラー |

## 検証

- 型チェック: `cd plugins && npm ci && ./node_modules/.bin/tsc -p ../plugins --noEmit`
  （CI の `Typecheck opencode plugin`）
- 実行時スモーク: `bash plugin-tests/smoke.sh`（env 契約と commit 誘導を検証。CI の
  `Plugin runtime smoke test`）

## 関連ページ

- [configuration.md](configuration.md) - `app.env` のキーとキャッシュ
- [environment.md](environment.md) - `CONAHCNUJ_SESSION_MODEL` などの変数一覧
- [installation.md](installation.md) - 配置手順
