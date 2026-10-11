# TODO: #269 owner-approved-auto-merge CI通過を待ってしまう

## 方針（issue 本文）
- 「merge if it's mergeable, or enable auto-merge」を実装する。

## 完了
- `.github/workflows/owner-approved-auto-merge.yml`: ポーリング（CHECK_TIMEOUT / outstanding_checks / sleep / statusCheckRollup / IGNORED_WORKFLOWS）を削除。
  承認 head（`--match-head-commit`）への即時マージ → 拒否されたら `gh pr merge --auto` でネイティブ auto-merge を有効化して終了。
  既に開いている PR でなければスキップ、`post-merge-dispatch` は実際にマージされたときだけ起動。`timeout-minutes` 30 → 10。
- `driver-tests/auto-merge-outstanding-checks.sh` を `driver-tests/auto-merge.sh` に置換:
  run ブロック抽出・「待ち（sleep / --watch / rollup）が残っていない」静的検証 + モック `gh` で分岐検証（即時マージ成功 / auto-merge 有効化で待たず終了 / 両方失敗 / head 変更・既 merge スキップ / dispatch はマージ確認時のみ）。
- ドキュメント更新: `README.md`・`docs/workflows.md`（auto-merge 節）・`docs/environment.md`（IGNORED_WORKFLOWS 行削除）・`AGENTS.md`（workflow 行・driver-tests 行）。

## 検証（済み）
- `bash -n` / `shellcheck -x` 全スクリプト clean
- `driver-tests/run.sh` 全テスト green（auto-merge.sh 含む）
- `gh-app/tests/run.sh` green
- `python3 docs/build.py --check` OK
- workflow YAML パース OK

## 残り（ドライバ担当）
- `.commit-msg` は作成済み。コミット・push・PR はドライバ。