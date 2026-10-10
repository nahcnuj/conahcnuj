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