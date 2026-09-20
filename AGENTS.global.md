# AGENTS.md (Global)

ユーザー全体の opencode 設定に関するルール。

## このファイルの目的

プロジェクト固有の `AGENTS.md` に加え、ユーザー全体の opencode 動作設定に関するガイドラインを提供します。`~/.config/opencode/opencode.json`（または `.jsonc`）が読み込まれる際の動作とカスタマイズに関するルールです。

## 基本ルール

- 設定値は `~/.config/opencode/app.env` から優先的に読み込まれます。ハードコードは避け、`app.env.example` をフォールバックとして使用してください。
- 秘密鍵（`.pem` 等）はリポジトリへコミットせず、`app.env` は `.gitignore` により無視されます。
- Windows で bash コマンドを実行する場合は常に `BASH_EXE`（`C:/Program Files/Git/bin/bash.exe`）を明示的に指定してください。WSL 経由の bash には対応しません。
- opencode 起動後の設定変更は、設定ファイルを保存後に opencode を再起動しないと反映されません（プラグイン・スキルは起動時ロード）。

## ファイルガイド

| パス | 役割 | 注意 |
| ---- | ---- | ---- |
| `~/.config/opencode/opencode.json` | プロジェクト設定を上書きするグローバル設定 | `$schema` を含め、不明なトップレベルキーはエラーとなります |
| `~/.config/opencode/app.env` | GitHub App 設定のプレースホルダー | `APP_ID` / `APP_SLUG` / `BASH_EXE` 等を記載。コミット時はプレースホルダのままにします |
| `~/.config/opencode/app.env.example` | `app.env` のテンプレート | プレースホルダ値のままコミットします |
| `~/.config/opencode/install.ps1` | グローバル設定のインストール/更新 | `~/.config/opencode` へ配置。実 `app.env` があればそれを使用し、無ければ `app.env.example` から作成します |
| `~/.config/opencode/plugins/` | opencode プラグインディレクトリ | `.ts` / `.js` ファイルが自動検出されます。`GhAppTokenPlugin` 等が配置されます |
| `~/.config/opencode/skills/` | opencode スキルディレクトリ | `**/SKILL.md` が再帰的にスキャンされます。スキルは `skills.paths` / `skills.urls` で追加可能です |
| `~/.config/opencode/references/` | リファレンス設定 | ローカルパスや Git リポジトリをaliasで参照可能です |

## ローカル検証手順

```powershell
# 構文チェック
powershell -ExecutionPolicy Bypass -File install.ps1

# スクリプト構文チェック（Windows bash）
bash -n gh-app/*.sh
shellcheck -x gh-app/*.sh

# offline モックテスト（秘密鍵・ネットワーク不要）
bash gh-app/mock-test.sh

# トークン取得の確認（実キーが app.env にある前提）
bash gh-app/get-token.sh

# 設定反映の確認
bash gh-app/setup-git.sh
git ls-remote https://github.com/<owner>/<repo>.git HEAD

# Verified コミット作成の確認（実キーとアクセス権がある前提）
bash gh-app/api-commit.sh <owner>/<repo> <branch> -m "message" --file file=@file
```

## 変更時の注意

- `install.ps1` や `plugins/`、`skills/` を変更したら、実機のグローバル設定（`~/.config/opencode/`）にも反映が必要：
  ```powershell
  powershell -ExecutionPolicy Bypass -File install.ps1
  ```
  その後 opencode を再起動。変更が反映されます。
- secrets を使う実機検証（`get-token.sh` / `api-commit.sh`）は行わず、ローカルで確認する。
- `opencode.json` / `opencode.jsonc` の不正なフィールドが含まれると opencode は起動を拒否します。不明なフィールドは `https://opencode.ai/config.json` で確認してください。

## コミット運用

- コミット・push はユーザーが明示的に指示したときだけ行う。
- GitHub App の秘密鍵や `app.env`、`token.cache` をステージしない。
- グローバル設定への変更後は、必ず opencode を再起動してください。