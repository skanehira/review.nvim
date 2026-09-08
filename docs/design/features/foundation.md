# foundation (プラグイン基盤)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。クイックモード)

## 何を作るか

review.nvim の骨格: `:Review` コマンド登録、`setup()` と config 合成、結果型、git/gh 実行アダプタ (`vim.system` + 外界 DI)、headless テスト基盤 (plenary)、Makefile / scripts、CI、`:help review`。diff-review ほか 4 機能のすべての前提。

## 入出力と振る舞い

- `require("review").setup(opts)` — opts を DESIGN.md「API 一覧」の既定値と shallow+deep 合成して内部 config に保存。2 回目以降の呼び出しも同じ opts + 既定値で再合成する (冪等)。不正値 (git_bin が実行不能など) は setup 時ではなく初回実行時に結果型で返す (起動を壊さない)
- `plugin/review.lua` — `vim.g.loaded_review_nvim` ガード + `:Review` を `nargs=* complete=customlist` (サブコマンド start/pr/list/close/delete/prompt) で登録し、args[1] でハンドラに振り分け (`:Review` 無印は復元)。引数個数の検証は各ハンドラ (`:Review start` は 1〜2、`:Review pr` は 1、`:Review delete` は 1)。本文は `require("review").command(...)` に委譲するだけ
- git/gh アダプタ `git/cli.lua` — `run(bin, args, opts, cb)`。`vim.system` を使い、コールバックは fast event 判定して `vim.schedule` で返し、`stdout` を結果型 `{ok, data={stdout, code}, error, code=E_GIT|E_GH}` に変換する。失敗時の `error` は stderr 末尾 1 行に整形 (ユーザー通知にそのまま使える文字列)
- 結果型とエラーコード (`core/result.lua`): `ok(data)`, `err(error, code)`。API 戻り値の結果型は同期的判定分のみを表し、git/gh 実行の結果はディスパッチ後に非同期 UI / notify で返す (DESIGN.md「API 一覧」の契約)。コードは `E_GIT`, `E_GH`, `E_REF`, `E_PR`, `E_WORKTREE`, `E_STORE`, `E_CANCELLED`, `E_NOT_ACTIVE`

## API

コマンドと Lua API の一覧は DESIGN.md「API 一覧」が正本。本機能で実装するのは入口の配線 (未知のサブコマンドは WARN 通知 + usage 1 行) と `run` のアダプタ。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| コマンド登録・委譲 | entry | `plugin/review.lua` |
| setup / config 合成 | facade | `lua/review/init.lua`, `lua/review/config.lua` |
| 結果型 | core | `lua/review/core/result.lua` |
| git/gh 共通実行 | adapters | `lua/review/git/cli.lua` |
| テスト初期化 | tests | `tests/minimal_init.lua` (`PLENARY_PATH` 未設定なら exit 1) |
| make ターゲット | tooling | `Makefile` (test / test-file / lint / format / format-check / check)、`scripts/run-tests.sh`, `scripts/lint.sh`, `scripts/plugin-check.sh`。`scripts/e2e.sh` と `make e2e` は最初のシナリオとともに session-ui (diff-review + persistence の UI 実装 issue) で作成する |
| CI | tooling | `.github/workflows/ci.yml` (test / lint / format / e2e の matrix。nvim v0.10.0 と stable) |
| ヘルプ | doc | `doc/review.txt` |

## エッジケースの決定

- git/gh 不在: 実行時「`git` が見つかりません」形式の WARN。setup は通す
- `plugin/review.lua` を 2 回 source しても二重登録しない (`vim.g` ガード)
- 並行実行中の同一 repo 操作 (dev-impl の worktree 並列実装前提): make ターゲットは一時ディレクトリを `mktemp -d` で取り、`trap` で掃除する (DESIGN.md「開発・検証コマンド」の契約)

## テスト方針

- 単体: config 合成 (既定値勝ち/負け)、結果型、`git/cli.lua` (`_set_system` 注入で擬似 system を差し替えて成功/失敗/fast event 経路)、コマンド委譲の未知サブコマンド
- E2E: headless nvim で `plugin/review.lua` が読み込まれ `:Review` が定義されること (`scripts/plugin-check.sh`、stderr 空で判定)
- CI green を foundation issue の DoD とする (dev-impl の検証コマンドは DESIGN.md「開発・検証コマンド」)
