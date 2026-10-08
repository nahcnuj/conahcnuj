# インストールと実行

このページはリポジトリの配置とドライバの実行方法をまとめます。設定値そのものは
[configuration.md](configuration.md) を参照してください。

## 前提

| 実行形態 | 必要なもの |
| --- | --- |
| ネイティブ（既定） | Windows + Git for Windows（`C:/Program Files/Git/bin/bash.exe`）、opencode、`git` / `curl` / `openssl` |
| Docker | Docker デーモン（ホスト側は `bash` + `git`） |

`install.ps1` の配置は pwsh が動けば Linux / macOS でも同じですが、CI での
検証は Windows のみです。配置せずにリポジトリ内から
`bash bin/conahcnuj.sh` / `bash gh-app/*.sh` を直接呼ぶだけなら
bash・git・curl・openssl で足ります。

opencode は既定で `~/.config/opencode/` をグローバル設定として読みます。

## `install.ps1`（ネイティブ配置）

```sh
git clone <repo>.git
cd <repo>
powershell -ExecutionPolicy Bypass -File install.ps1
```

| パラメータ | 既定 | 内容 |
| --- | --- | --- |
| `-Destination` | `$HOME/.config/opencode` | opencode 設定ディレクトリ |
| `-InstallPath` | `$HOME/.local/bin` | `conahcnuj` コマンドの置き場 |

配置されるもの:

- `<Destination>/gh-app/...` - opencode プラグイン用（プラグイン自身の相対解決先）
- `<InstallPathParent>/gh-app/...` と `<InstallPathParent>/lib/*.sh` -
  ドライバ用（ドライバは自分自身から gh-app / lib を解決する。**2 箇所**へ配備）
- `<Destination>/plugins/gh-app-token.ts` - opencode プラグイン
- `<InstallPath>/conahcnuj` - ドライバ本体（`bin/conahcnuj.sh`）
- `app.env` が無ければ `app.env.example` から作成

`plugins/package.json`・`package-lock.json`・`tsconfig.json`・`node_modules`・
`gh-app/tests` などのテスト資材は**配備しません**（型チェック用・検証用に
リポジトリ内だけに置く）。

手順:

1. `<Destination>/gh-app/app.env` に実値を書く
2. opencode を再起動（プラグインは起動時ロード）
3. `gh auth status` が bot アカウントを示すことを確認

更新も同じコマンドです（配置し直してから opencode を再起動）。
CI の `install.ps1 deployment test` が同じ配置を検証しています。

## Docker で実行（隔離）

自律実行（opencode が作業ツリーを自由に編集する）をホストから隔離したい場合は
イメージ内でドライバを動かします。

```sh
cd <対象リポジトリ>
bash <このリポジトリ>/docker-run.sh <issue-or-PR番号>
```

- `Dockerfile` は opencode・git・curl・openssl・ドライバを同梱。
  **秘密鍵と `app.env` は焼き込まない**
- 対象リポジトリは `/work` にバインドマウント（ホストのツリーは汚さない）
- ホストの `gh-app/app.env` から `APP_ID` / `INSTALLATION_ID` / `APP_SLUG` /
  `PRIVATE_KEY_PATH` を読み、コンテナ用 `app.env`（`BASH_EXE=/usr/bin/bash`、
  鍵はマウント先）を生成して渡す
- 秘密鍵は `/run/secrets/app.pem` に**読み取り専用**でマウント
- opencode の設定・認証（`~/.config/opencode` / `~/.local/share/opencode`）が
  あれば読み込み、ホストと同じモデルが使える
- 既定は foreground。`CONAHCNUJ_DAEMON=1` で detached（`docker logs -f <名前>` で追える）
- 上書き変数は [environment.md](environment.md) を参照

## ドライバの実行

```sh
conahcnuj <issue-or-PR番号>
```

詳細なフロー・終了コード・エージェント契約は [driver.md](driver.md)、
GitHub 上での自動実行は [workflows.md](workflows.md) を参照してください。

## 導入後の確認

```sh
bash gh-app/get-token.sh            # トークンが取れる（末尾改行なしのまま出る）
bash gh-app/setup-git.sh            # bot 名義の git config が入る
git ls-remote https://github.com/<owner>/<repo>.git HEAD   # 認証の疎通
bash gh-app/api-commit.sh -m "message" -a --dry-run        # 収集結果の確認（ネットワーク不要）
```

トラブルシューティング:

- `gh auth status` が自分のアカウントを示す → トークンが取れていない。
  `BASH_EXE` が正しい Git Bash 経路か、`app.env` の値を確認して opencode を再起動
- トークンが取れない → `bash gh-app/get-token.sh` を直接実行して出力・
  stderr を確認（`token.cache` を削除して再実行）
- CI は秘密鍵・ネットワーク不要の offline 検証のみ。実トークンの確認はローカルで
  上記コマンドを実行

## 関連ページ

- [configuration.md](configuration.md) - `app.env` のキー
- [plugin.md](plugin.md) - 配置されるプラグインの挙動
- [cli.md](cli.md) - 確認コマンドの仕様
