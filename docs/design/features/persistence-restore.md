# persistence-restore (セッションの永続化と復元)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。MUST 2)

## 何を作るか

レビューセッション (差分対象・コメント・viewed 状態) を JSON 1 ファイルへ永続化し、Neovim 再起動後に 1 操作で復元できるようにする。データ形式は DESIGN.md「データスキーマ」が正本。INV-4 (CRUD 直後の永続化) を store 層で担保する。

## 入出力と振る舞い

**保存 `store.save(session)`**:

1. パスは `<stdpath("data")>/review.nvim/sessions/<sha1(repo) 先頭 16 桁>/<slug>.json` (dir は `mkdir -p` 相当で作成)
2. tmp へ全量 JSON を write → `os.rename` で差し替え (同一 fs 内でアトミック)
3. `updated_at` を更新。書き込み失敗 (権限・ディスク) は `E_STORE` 通知。UI 操作自体はロールバックせずメモリ上の状態を維持する (次 write で再挑戦)

**読込 `store.load(repo, id)` / `store.list(repo)`**: `version` 不一致または JSON パース失敗は元内容を `.corrupt` サフィックスで退避してから「存在しない」扱いにし WARN。退避後は同名ファイルが消えているので、以降の save は新規ファイル作成として働く (退避データを上書きで汚染しない。`.corrupt` の削除は手動)。実在するが読み取れないファイル (権限付与ミス等) は退避せず WARN のみ出して「存在しない」扱いとする: 退避元の読み取りが不能なのだから退避先の `.corrupt` も同じ理由で読めず隔離の意味がないためで、DESIGN.md「横断規約」永続化の「読み込み失敗は…通知する」は WARN で満たす (ファイルは原地に残るため、権限復帰後の次回 save/rename がそのまま上書きする)

**起動時 (`VimEnter`、`auto_notify_resume=true` のとき)**:

1. cwd が git repo 内なら repo top を解決し、その repo の `status=open` セッションを scan
2. 1 件以上あれば notify: `review.nvim: <slug> のレビューが続けられます (:Review で復元)` (複数なら個数と代表 slug)。自動で窓は開かない
3. worktree 残骸の掃除は pr-worktree「異常終了からの回復」が同じ scan を読んで実行する

**復元 `:Review` (引数なし)**:

- open セッション 1 件 → 即復元。複数 → vim.ui.select (slug + base..head + コメント数)。該当 0 件 → 新規開始ガイダンス通知 (`:Review start で開始`)
- 復元手順: active セッションがあれば確認後に save → close してから開始 (INV-1。diff-review「開始と既存セッションの継承」と同じ規則) → load → (base/head が force push・ブランチ削除等で解決不能なら WARN 通知で開かない。セッションはそのまま保存される) → diff を再取得・再パース → anchor 検証でコメントの位置と state を更新 → UI → worktree を pr-worktree の作成判断で解決 (既存ディレクトリがあれば再利用、無ければ作成/再作成) → status=open で save

**anchor 検証 (復元時の位置整合)**: 差分は再取得されるため行番号は変わる。コメントごとに (a) 保存行番号の行テキスト == `anchor.line` → active 維持、(b) 同一ファイルの保存行番号 ±20 行以内に `anchor.line` と一致 → active にして保持行番号を補正、(c) 見つからない → `state=outdated`。outdated でも `line` / `end_line` の値は書き換えない (保存値のまま保持)。表示上、その行が new 側差分に存在しない場合は当該ファイルの diff バッファ ヘッダ行に `⚠ outdated: <抜粋>` の virt text で一覧表示する。補正・outdated 化の結果は復元時に save して次回以降の検証を省く

**`:Review list`**: 当該 repo の保存済みセッション全件を scratch split window (filetype `review-list`) に一覧表示 (slug / status / mode / base..head / コメント数 / 更新時刻)。キーは DESIGN.md「デフォルトキーマップ」の sessionlist 行 (`<Enter>` で開く = 復元手順を実行、closed → open)。repo path 消失のセッションは grey 表示で `<Enter>` 不可。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| セッション JSON の読書・アトミック書込・退避 | store | `lua/review/store/session.lua` (+ `_spec`) |
| slug / repo-hash 生成 | store | `lua/review/store/paths.lua` (+ `_spec`) |
| open セッション scan (notify と worktree掃除兼用) | store | `lua/review/store/scan.lua` (+ `_spec`) |
| 復元フロー (diff 再取得と anchor 検証の調停) | handlers | `lua/review/handlers/restore.lua` |
| `:Review list` / `:Review delete` のフロー (delete は close 掃除の再利用) | handlers | `lua/review/handlers/sessions_list.lua`, `lua/review/handlers/session.lua` (delete 拡張) |
| セッションファイル削除 | store | `lua/review/store/session.lua` (`delete(repo, id)`) |
| VimEnter フック登録 | facade | `lua/review/init.lua` (setup 内) |

## エッジケースの決定

- セッションの一意性は refs 組 = slug が決める (1 組 1 セッション)。分岐は `<base>--<head>`、PR は `pr-<n>` なので両モード間で衝突しない。ref 名由来で稀にある別 refs 組との slug 衝突は、新規作成を拒否し既存セッションを案内して解決する (`:Review delete` で削除可)。同一 refs 組の再開始は新規ではなく継承 (diff-review「開始と既存セッションの継承」)
- repo があるべき path に無い (移動・削除済み): load 不能を通知し、そのセッションは list に grey 表示 (開けない旨)。掃除しない (ユーザーの判断待ち)
- 差分が復元時にまるごと消滅 (rebase / squash で再取得した base 間 diff が空): 開くことを拒否せず、UI を開く (diff バッファは「変更なし」表示、全コメントを outdated として、通常時と同じく当該ファイルのバッファヘッダ行の `⚠ outdated: <抜粋>` virt text に一覧表示)。プロンプトは outdated 除外で実質空になる (ai-prompt)。ユーザーは確認の上 `:Review close` / `:Review delete` する
- write 失敗後の UI: コメント作成はメモリ上で成功扱い。WARN を 1 回出し、次の成功 save まで失敗状態を維持 (INV-4 の留保と同じ Exception)
- 破損データは `.corrupt` サフィックスで正常経路から隔離し、自動削除はしない (片付けは手動)
- 複数 nvim インスタンスが同一セッションを open すると最後が勝つ (last-write-wins)。ロックは持たない (v1 の明確な決定として記録)

## テスト方針

- 単体 (store): tmpdir を注入して save→load 往復、アトミック差替え (rename 失敗の再現)、破損→corrupt 退避、version 不一致、読取不能→退避せず WARN (chmod での権限喪失注入)、slug/hash 決定性
- 単体 (restore の anchor 検証): 合成 diff に対して (a)(b)(c) の 3 経路と、±20 境界 (21 行ずれたら outdated)
- E2E (golden path、MUST 2 の実証): fixture repo でコメント作成 → **headless nvim プロセスを kill せずに普通に終了** → 新プロセスで `VimEnter` の notify → `:Review` 復元 → 本文と位置が同一であることを assert (e2e.sh の 1 本目シナリオに組み込む)
