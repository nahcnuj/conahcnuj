# 自己研鑽（週次の auto-drive ログ解析）

「Issue auto-drive」の実行ログは Actions の実行ログとしてしか残りません。毎週、
その週の実行を解析して次の週の改善 issue に取り込む自己研鑽ループが
`bin/auto-drive-report.sh` と `bin/auto-drive-workflow.sh` です。ドライバ自身が
自分の失敗（バグ報告・全モデル失敗・時間予算枯渇・想定外の終わり方）を拾って、
`github-actions[bot]` 作の issue として次の実行へ渡します。

- 解析は純 bash + awk で offline に動く（jq / node 不要・シークレット不要）
- 通信は `gh` CLI のみ。テストはモック `gh` を使う
  （`driver-tests/auto-drive-report.sh` / `auto-drive-workflow.sh`）

## ファイル

| パス | 役割 |
| --- | --- |
| `bin/auto-drive-report.sh` | ログ解析。ログのパス群を渡すと markdown レポートを stdout へ出力（1 ログ = 1 run）。`--runs-url-prefix` で `run-<id>.log` に実行 URL を付ける。解析できた run の数をメタ行 `<!-- auto-drive-report runs=N findings=N actionable=N -->` で出す |
| `bin/auto-drive-workflow.sh` | 週次ループの実体。Actions API で直近のログを集め、レポートを「auto-drive weekly self-improvement log」issue に載せ、actionable な finding があれば「auto-drive findings」issue へまとめて `issue-driver.yml` を `workflow_dispatch` する |
| `.github/workflows/weekly-self-improvement.yml` | 上をスケジュールで回す（月曜 01:17 UTC・手動実行あり） |

## 手順

1. **収集**: `gh api` で `issue-driver.yml` の直近 `--lookback-days`（既定 `7`）の
   完了済み run を取得し、`gh run view --log` でログをダウンロード（上限 40 run）。
   ログが取れない run は WARNING 扱いでスキップ
2. **解析**: `auto-drive-report.sh` でレポートを作成（stdout）。先頭のメタ行
   `<!-- auto-drive-report runs=N findings=N actionable=N -->` が機械可読な要約
3. **公開**: レポートをトラッキング issue「auto-drive weekly self-improvement log」へ
   （初回のみ作成、以降はコメント追記）
4. **引き渡し**: `actionable > 0` かつ drive が有効なときだけ、findings を
   「auto-drive findings: `<日付>`」issue へまとめ（初回のみ作成）、
   `workflow_dispatch` で `issue-driver.yml` を起動

## finding の分類

| アウトカム | 例 | 種別 |
| --- | --- | --- |
| `environment-down` | 全プロバイダが環境エラーで終了 | informational |
| `handoff-unconfirmed` | レビュー依頼の読み返しが読めなかった | informational |
| `no-model-completed` | どのモデルも完了できなかった | actionable |
| `time-budget-exhausted` | `CONAHCNUJ_MAX_SECONDS` を使い切った | actionable |
| `bug-reported` | バグ報告 issue が作られた（異常終了） | actionable |
| `unknown` | 想定外の終わり方 | actionable |
| `no-driver-output` | ログが空（収集・転送の不具合） | actionable |

- **informational** はコード変更不要（プロバイダ障害は再実行、読み返し失敗は
  WARNING 相当）なのでドライバへ渡さない
- **actionable** は「auto-drive findings」issue に入り、次週のドライバ実行が
  これを材料に調査・修正する（ブランチ・コミット・PR・レビュー依頼はドライバ担当）

## ループの衛生（再帰しない理由）

- findings issue は `github-actions[bot]` 名義で作るため、`issues-opened` トリガは
  bot をスキップし、この issue が開いてもドライバは自動では起動しない
- `GITHUB_TOKEN` 起因のイベントは workflow を起動しない
  （`workflow_dispatch` / `repository_dispatch` が唯一の例外）
- 唯一の入口は明示的な `workflow_dispatch`。開く findings issue は常に 1 件、
  dispatch も週 1 回
- どのドライバ実行も最後は owner のレビューで終わる（findings issue も同じ）

## 無効化・試運転

- 手動実行（`workflow_dispatch`）で入力 `drive: false` を選ぶと、レポートの公開
  だけ行いドライバは起動しない（試運転・影響確認用）
- 一時停止するなら `schedule:` の cron を消すか `concurrency:` グループを変更

## 関連ページ

- [workflows.md](workflows.md) - `weekly-self-improvement.yml` と他の workflow
- [driver.md](driver.md) - 解析対象となるドライバの実行ログ
- [environment.md](environment.md) - `lookback-days` / `drive` 入力の既定値