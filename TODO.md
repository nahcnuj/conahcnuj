# Issue #158
## Summary
何らの変更を生み出せないまま散っていく情けない姿を見ていられないので、リポジトリルートにTODO.mdを作成して進捗を管理・共有しましょう。

```sh-session
opencode/ling-3.0-flash-fin-free@nahcnuj/***:.  5ccea73 [***/155-Rate-limit-exceeded] +0/-0
  ❌️ Error from provider (Console): Upstream request failed: Endpoint is unavailable.
Model opencode/ling-3.0-flash-fin-free failed before completing the work: environment error (provider unreachable or credentials rejected); giving up on provider opencode for the rest of this run.
```

### Goals

* リポジトリルートの TODO.md で進捗を管理・共有する
    * ファイルの存在は AGENTS.md で知らせること
    * 生存期間は **issue 毎**。
        * issue の着手でファイルを作成
        * 作業中、随時進捗に応じて TODO.md を更新させる
        * 対応が完了し ready to merge するときには TODO.md が**削除**されていること
            * TODO.md がある状態では自身で Draft を解除できない（DraftでないPRを作成できない）ように

### Non-goals

* TODO.mdの書式など

## TODO List
- [ ] リポジトリルートの TODO.md で進捗を管理・共有する
<!-- (This file can be removed, if once left no undone tasks) -->
