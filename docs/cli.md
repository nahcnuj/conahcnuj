# CLI リファレンス（`gh-app/`）

GitHub App のトークン発行から Verified コミット作成までを行うシェルスクリプト群の
リファレンスです。いずれも **bash** を要求し、API を呼ぶものは `curl`、署名・
デコードをするものは `openssl`、`api-commit.sh` は加えて `git` を要求します。
設定は [configuration.md](configuration.md) の `gh-app/app.env` から読みます。
終了コードは `0` = 成功、`1` = エラー（理由は stderr）。

| スクリプト | 役割 |
| --- | --- |
| [get-token.sh](#get-tokensh) | JWT 署名 → インストールトークン取得（キャッシュ付き） |
| [git-credential-helper.sh](#git-credential-helpersh) | git の credential helper としてトークンを供給 |
| [setup-git.sh](#setup-gitsh) | リポジトリへ bot 名義の git config を適用 |
| [bot-user-id.sh](#bot-user-idsh) | bot アカウントのユーザー ID を出力 |
| [api-commit.sh](#api-commitsh) | GraphQL でブランチに Verified コミットを 1 件作成 |

## get-token.sh

```sh
bash gh-app/get-token.sh                 # インストールトークンを stdout へ
bash gh-app/get-token.sh --print-pem-path # 解決済みの秘密鍵パスを stdout へ（改行付き・ネットワーク不要）
```

手順:

1. `token.cache` が有効ならそれを返す（ネットワーク不要）
2. 秘密鍵で RS256 署名の JWT を作る（`iat` = 現在、`exp` = 現在 + 540 秒）
3. `POST {GH_APP_API_BASE}/app/installations/{INSTALLATION_ID}/access_tokens` と交換
4. `token.cache` へ `期限|トークン` として保存し、トークンを stdout へ出力

- **stdout**: トークン文字列（**末尾に改行なし**）。stderr には何も出さない
- 失敗時: `ERROR: failed to fetch installation access token` を出して exit 1
- `PRIVATE_KEY_PATH` は `~` 展開と WSL `/mnt/<d>/...` → `/<d>/...` の解決を通過する
- シェルと opencode プラグインが同じキャッシュを共有する

## git-credential-helper.sh

git が credential helper を呼んだときのプロトコル実装です（`setup-git.sh` と
プラグインが `credential.helper` に登録）。

```text
git → <helper> get   （要求を stdin で渡す）
stdout: username=x-access-token
        password=<インストールトークン>
```

- `get` 以外（`store` / `erase` / その他）は stdin を読み捨てて exit 0
  （保存・消去するものはない）
- トークン取得は [get-token.sh](#get-tokensh) に委譲

## setup-git.sh

リポジトリのルートで実行し、bot 名義の git config を適用します。

| 設定 | 値 |
| --- | --- |
| `user.name` | `<APP_SLUG>[bot]` |
| `user.email` | `<BOT_USER_ID>+<APP_SLUG>[bot]@users.noreply.github.com` |
| `credential.helper` | `!"<BASH_EXE>" "<gh-app>/git-credential-helper.sh"` |
| `commit.gpgsign` | `false` |

- スコープは `--local`（git リポジトリ内）。リポジトリ外では `--global` に
  落ちて WARNING を出す
- bot ID が未キャッシュなら公開 API を叩くため初回はネットワークが必要
  （[bot-user-id.sh](#bot-user-idsh)）
- ドライバは起動時に自動でこれを実行する（`CONAHCNUJ_TEST_MODE=1` では除く）
- 設定後は `git ls-remote https://github.com/<owner>/<repo>.git HEAD` で疎通確認

## bot-user-id.sh

bot アカウントのユーザー ID を **stdout へ（改行なし）** 出力します。解決順:

1. `app.env` の `BOT_USER_ID`（プレースホルダ値は無効扱い）
2. `gh-app/bot-id.cache`（不変のため無期限）
3. 公開 API `GET {GH_APP_API_BASE}/users/<APP_SLUG>%5Bbot%5D`（認証不要）→
   成功したらキャッシュへ保存

いずれも不可なら、`BOT_USER_ID` を設定すべき旨（`gh api users/<slug>%5Bbot%5D
--jq .id` の形式）を stderr へ出して exit 1。`APP_ID` は fallback にしない。

## api-commit.sh

GitHub GraphQL の `createCommitOnBranch` で、ブランチ先端に **Verified 署名付きの
コミットを 1 件**作成します。コミットは GitHub 側で作成されるため（committer は
GitHub）、`Commits must have verified signatures` のようなブランチルールを満たします。
`git commit`（unsigned）の代替として使います。

```sh
bash gh-app/api-commit.sh -m "<メッセージ>"                # staged の内容（git commit 相当）
bash gh-app/api-commit.sh -m "<メッセージ>" -a             # tracked 変更（git commit -a 相当）
bash gh-app/api-commit.sh -m "<メッセージ>" -a --delete path/to/removed
bash gh-app/api-commit.sh <owner>/<repo> <branch> -m "<メッセージ>" -a
bash gh-app/api-commit.sh <branch> -m "<メッセージ>"       # owner/repo は origin から自動検出
bash gh-app/api-commit.sh -m "<メッセージ>" --create-branch --dry-run
```

### オプション

| オプション | 内容 |
| --- | --- |
| `-m`, `--message <text>` | **必須**。1 行目が headline、続く行が body |
| `-a` | tracked な作業ツリー変更を収集（修正・削除・リネーム含む。**untracked は除外**） |
| `-d`, `--delete <path>` | ブランチからパスを削除（複数回指定可） |
| `--create-branch` | ブランチが無いとき、デフォルトブランチ起点で ref を作成（unsigned コミットを経由しない） |
| `--dry-run` | API を呼ばず収集結果のみ表示（トークン・ネットワーク不要） |

位置引数は先頭から `[<owner>/<repo>] [<branch>]`。省略時は `git remote origin` と
現在のブランチから自動検出します（リポジトリ外・remote 無しはエラー）。

### 収集モード

| モード | 収集元 | 備考 |
| --- | --- | --- |
| 既定（`-a` / `-d` なし） | index（`git show :path`） | `git add` 済みの内容。`git commit` 相当 |
| `-a` | 作業ツリー（`git status --porcelain`） | `git commit -a` 相当。新規ファイルは `git add` が要る |
| `-d` のみ | 追加なし・指定パスの削除のみ | |

- 1 実行でコミットは **1 件だけ**。履歴の書き換え・force-push はしない
- 既存ブランチに unsigned コミットが混ざっている場合は、先に
  `git fetch origin` → `git reset --hard origin/<branch>` で作り直してから使うこと

### Model trailer

`CONAHCNUJ_COMMIT_MODEL` が 1 行のラベルなら、コミット本文末尾に
`Model: <ラベル>` trailer を追加します（既に `Model:` を含むメッセージは無改変）。
未設定なら付きません。opencode では [plugin.md](plugin.md) がセッションのモデル名を
この変数へ入れています。

### 入出力

- **stdout**: 成功時、作成したコミットの SHA（**末尾に改行なし**）。SHA の直前に
  ローカル同期（`git pull origin <branch>`）の出力が入るため、**最後の行**を読む
- `--dry-run` の stdout: `Owner/Repo:` / `Branch:` / `Message:` / `Additions:` /
  `Deletions:` のレポート
- stderr: `Created branch <branch> from <default>`（`--create-branch` で ref を作った
  とき）、エラー理由
- 作者（author）は App の bot、committer は GitHub

### 前提

- ネットワーク + 有効なトークン（`--dry-run` は不要）
- 収集内容が 0 件なら `ERROR: nothing to commit ...` で exit 1
- ブランチが無く `--create-branch` も無い場合:
  `ERROR: branch <branch> not found ...` で exit 1

## 関連ページ

- [configuration.md](configuration.md) - `app.env` とキャッシュの詳細
- [plugin.md](plugin.md) - opencode 内では `git vc` がこのスクリプトを指す alias
- [driver.md](driver.md) - ドライバがこのスクリプトを使う流れ
