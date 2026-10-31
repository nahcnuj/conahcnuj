# conahcnuj のグローバルルール

このファイルは `install.ps1` によって **opencode のグローバル設定
`~/.config/opencode/AGENTS.md`** へ配置される（conahcnuj の管理ブロックとして、
既存のファイルがあればその他の内容を保ったまま追記・更新される）。opencode は
グローバル AGENTS.md を全セッションへ読み込むため、nahcnuj のどのリポジトリでも
同じ指示が効く。個別リポジトリに同じことを書く必要はない。

## コミットは `git vc`

- **コミットは `git vc` で行うこと。`git commit` は使ってはいけない。**
  この環境（conahcnuj）では git が GitHub App 名義で動くため、`git commit` が
  作るコミットは署名なしになり、「Commits must have verified signatures」等の
  ブランチルールで弾かれる（bot アカウントには署名鍵を登録できない）。
- 使い方は `git commit` と同じ:

  ```sh
  git add <paths>                 # 新規ファイルは通常の git どおり add する
  git vc -m "<message>"           # staged の内容をコミット（git commit 相当）
  git vc -m "<message>" -a        # tracked の作業ツリー変更（git commit -a 相当）
  ```

- `git vc` は conahcnuj の opencode プラグイン（`plugins/gh-app-token.ts`）が
  セッションのシェルへ注入する git alias で、内部で `gh-app/api-commit.sh` を
  正しい owner/repo/branch 付きで呼ぶ。**`api-commit.sh` を直接実行しないこと**
  （直接実行はフックに止められ `git vc` へ誘導される）。
- **`gh-app/` 配下のファイル（特に `gh-app/api-commit.sh`）は編集・変更しないこと。**
  これらは verified commit 機構の実装詳細であり、変更する必要はない。
- 自然と `git vc` を使うことを心がける（`git commit` の代わりに `git vc` を選ぶ）。
- コミットを求められていないタスクでは、コミットせず作業ツリーに変更を残す。

## GitHub CLI / API は認証済み（`GH_TOKEN`）

- **`gh` と GitHub API は conahcnuj のプラグインが認証済みにする。** セッションが
  起動する各シェルには GitHub App のインストールトークンが `GH_TOKEN` として
  設定されているので、`gh api ...` などをそのまま実行すれば App 名義で動く。
- **`GH_TOKEN` を自分で export しないこと。`gh-app/get-token.sh` を実行して
  トークンを取り直す必要もない。** トークンはプラグインがシェルごとに（期限が
  切れていれば更新して）注入するので、自分で用意すると冗長で壊れやすい。

## シェルの移植性（まず環境を確認する）

- **まず自分がどの OS・シェルで動いているかを確認すること。** 実際に動いている
  環境を自分で把握してからコマンドを選ぶこと（Windows のデフォルトシェル
  (PowerShell) でも Git for Windows 由来で `head` / `tail` / `grep` が使える
  ようになったので、シェルコマンドとして使ってよい）。Windows 環境では
  PowerShell を使うこと: PowerShell のコマンドレットや組み込み機能を優先し、
  コマンドの有無は `Get-Command` で確認し、空白を含むパスは引用符で囲むこと。
  Windows 以外の環境ではそのシェル自身のコマンドや node/python を使うこと:
  コマンドの有無は `command -v` で確認すること。**Windows 以外の環境で
  `powershell` / `pwsh` を実行しないこと**（存在せず `The term 'powershell' is not
  recognized...` になる）。ファイルの読み取りは read
  ツール、検索は grep/glob ツールを優先すること。シェルコマンドが避けられない
  場合は、その環境で利用可能なコマンドや node/python を使うこと。
  コマンドが存在するか分からないときは先に確認すること。
- **`node` / `npm` は PATH に入っています。** conahcnuj のプラグインが opencode
  自身を動かしている Node のディレクトリを PATH に追加するので、`node` や
  `npm` を使うためにファイルシステムを再帰検索したり fnm/nvm を手動で有効化
  する必要はありません。コマンドの有無は `Get-Command` / `command -v` で確認
  してください。
- **`/dev/null` は Unix の null デバイスであり、Windows の PowerShell には
  存在しません。** PowerShell では `$null`（例: `2>$null`）や `Out-Null` を
  使ってください。`/dev/null` や `2>/dev/null` を PowerShell で使うと
  `C:\dev\null` というファイル作成を試みて失敗します。
- **行継続もシェル依存です。** PowerShell ではバッククォート (`` ` ``) を使い、
  バックスラッシュ (`\`) は使えません（Unix シェルの継続文字です）。
- **PowerShell では `&&` は文の区切り文字として使えません（このバージョンでは
  `The token '&&' is not a valid statement separator in this version.` になります）。** コマンドを
  連結するときは `;` を使うか、コマンドを別々に実行すること。`&&` を
  PowerShell で使わないこと。
