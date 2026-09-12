# pr-worktree (PR レビューと git worktree 連携)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。MUST 4)

## 何を作るか

`gh` CLI で PR を解決し、head を git worktree にチェックアウトした状態でレビューセッションを開始する。**worktree はモード pr のみ** — ブランチレビューは現在のチェックアウトを直接レビューする (DESIGN.md「worktree 作成条件」。head が現在の HEAD と違うときだけ switch 提案 / scratch 縮退、diff-review「head 解決フロー」)。レビューは専有 tab を worktree に `tcd` して開き、head 窓が **worktree 内の実ファイル** になる (編集可・LSP attach)。セッション終了時に worktree とレビュー tab・張った extmark をクリーンアップする。作成・消去のロジックは DESIGN.md「既知の制約」の worktree・crash・fork PR・Windows の各行に従う。

## 入出力と振る舞い

**PR 解決** `:Review pr <number|url>`:

1. url からは PR 番号を抽出 (`/pull/<n>` 末尾)。番号解決は `gh pr view <n|url> --json number,title,baseRefName,headRefName,headRepositoryOwner,url,state` を実行。gh 不在・未 auth・PR 非存在は `E_GH` / `E_PR` を通知 (`state` は closed/merged PR の開始時 INFO 注記に使う)
2. head ref の用意: 同一リポジトリの branch なら `<headRefName>` をそのまま使い、それ以外 (fork) は `git fetch <remote> refs/pull/<n>/head:review-nvim/pr-<n>` を実行 (ref 名は決定的なので次回以降 fetch で上更新可)。remote 選択は default remote に無ければ origin で試す
3. base/head (ブランチ名 / fork なら fetch した一時 ref) で **worktree を作成 (add) してから**、`git diff <base>` (cwd=worktree、**作業ツリー基準**) を取得 → 以降 diff-review と同じ UI を開く (tab は作成済み worktree に `:tcd`。PR タイトルは開始時に INFO 通知するだけ。セッションには永続化しない)

**worktree 作成判断** — 作成するのはモード pr のみ。「レビュー対象の状態」を worktree の実ファイルとして成立させるための規則 (DESIGN.md 決定表と同一):

| 条件 | worktree |
| --- | --- |
| mode=branch | **作らない**。現在のチェックアウトを直接レビューする。head が現在の HEAD と違う場合のみ switch 提案 or scratch 縮退で対応し、worktree で回避しない (diff-review「head 解決フロー」。head が作業ツリー基準になった今、別ツリーで commit 内容を見せる意味がない) |
| mode=pr | `git worktree add --detach <path> <head>` (path = `stdpath("data")/review.nvim/worktrees/<repo-hash>/<slug>`)。**`--detach` を使うので branch checkout と競合しない**。slug は repo 単位にしか一意でないため `<repo-hash>` 下で分離する (別 repo の同一 slug が同 path で衝突するのを防ぐ) |
| PR かつ head が fork 由来 (同一 repo に headRefName の branch が無い) | 上記に先立ち `git fetch <remote> refs/pull/<n>/head` で `review-nvim/pr-<n>` ref を作り、それを `<head>` として worktree を作成 |

作成失敗 (パス衝突) は既存同名ディレクトリを `git worktree prune` で回収試行 → 改善しなければ `E_WORKTREE` 通知で開始を中断。**衝突した残骸が自分の作成分 (`created_by_us=true` の記録あり) でない限り自動削除しない** (INV-3)。

**head 窓と実ファイル (`o`)**:

- head 窓そのものが worktree 実ファイル (`:edit`、編集可・LSP attach)。レビュー中の編集は保存でリフレッシュされ、差分・カウント・prompt に反映される (diff-review「リフレッシュ (未コミット反映契約)」)
- `o` = そのファイルの実ファイルを**前行儀の tab** で `:edit` (レビュー tab の窓 diff を壊さず通常編集・移動経路へ出る)。worktree セッションでは `<worktree>/<path>`、branch 通常経路では `<repo>/<path>` を開く
- head 窓で編集した内容はセッション保存対象ではない (保存されるのは comments / viewed / refs のみ。編集がディスクにある限り復元後のレビュー内容に現れる — branch/PR 共通、DESIGN 不変条件 INV-4)
- レビュー対象のファイルそのものが無い (削除ファイル) head 窓は告知 scratch のみで編集不可。base 窓側の削除前コンテンツは読める

**セッションとレビューの終了 (`:Review close` / `q`)** — 順序の原則: ユーザーデータを失いうる操作の判定と確認を、状態変更より前に行う (`q` と `:Review close` は同一経路):

0. comments > 0 なら «コメント N 件あります。レビューを終了しますか?» [y/N] (キャンセル = 終了を最初から中止)。0 件なら確認しない
1. worktree 作成済みなら `git -C <worktree-path> status --porcelain` で未コミット変更を検知。変更ありなら `--force` で削除してよいか確認 (キャンセル = **close を最初から中止**。セッション・UI・保存状態は何も変わらない)。変更なしなら確認不要で続行
2. 現セッションを save して status=closed、active を解除、**レビュー専有 tab を閉じる**。閉じる前に、このセッションが張った全バッファ (head 実ファイル・scratch) の extmark namespace を明示 clear (残骸 0)。ユーザーが編集途中 (modified) で残した実ファイルバッファも消さずに窓だけ閉じる
3. worktree を `git worktree remove <path>` (1 で force 承認済みなら `--force`) で削除。**自前 ref (`review-nvim/pr-<n>`) は close では消さない** (再開時に fetch を省略して再利用するため)
4. 掃除失敗 (`remove` の失敗等) は WARN を出し、**二段目として `git worktree prune` + 自前 dir の再帰削除で自己修復する** (登録と dir の対応が崩れた形 = `does not point back` は prune が正すのが git の手順)。dir 削除まで失敗した場合のみ追加 WARN し、close (save・タブクローズ) 自体は完了させる。残骸は起動 scan が closed + dir 残骸として回収する

**worktree 登録操作の直列化**: 同じ dir path に対する `git worktree remove` (close / delete) と `git worktree add` (start / resume の作成判断〜作成) は、セッション内で 1 本ずつ直列に実行する。remove は管理登録の解除 + ツリー削除の重い git I/O で、その最中に同じ path へ add すると remove の中間状態を跨いで再登録となり、git が衝突しない管理名 (`main--issue-4` + `main--issue-41` の形) で同一 dir を二重登録することがある (以後の remove が "does not point back" で失敗し続け、close するたびに WARN が出る実測状態)。add 側は読み取り (diff 取得など) を待たず、**登録を作る経路 (resolve_worktree の判断〜作成〜完了、remove 連鎖の完了) だけが待機する**

**セッションの削除 (`:Review delete <id>`)**: 入力時に確認 (`コメント N 件を削除します`)。active と同じ id なら close の 1〜3 を先に実行してから、セッション JSON ファイルを削除し、このセッション用に作った `review-nvim/pr-<n>` ref があれば消す。closed でも `created_by_us=true` の worktree 残骸 (close の掃除失敗経路で発生しうる) があれば close の 3〜4 と同等の掃除を行ってからファイルを削除する (孤児 dir を残さない)。削除は不可逆で、undo は提供しない。

**異常終了からの回復 (起動 scan、persistence-restore の scan を利用)**:

- 記録上 open のセッションについて worktree path の実在を確認。実在して repo の `git worktree list` に載っていればそのまま復元で再利用する (crash 後でも worktree は使える)。記録にあるのにディレクトリが消えていれば worktree=null にして save し、復元時の作成判断 (persistence-restore「復元手順」) で作り直す
- `created_by_us=true` の worktree のうち、セッション側が closed なのにディレクトリが残っている残骸を「掃除してよい残骸」として通知し、`git worktree prune` + ディレクトリ削除で回収する。**closed の掃除ではセッションファイルを書き戻さない** (dir 消滅後の記録は以後 scan に出ないため放置で無害。書き戻しは `:Review delete` の JSON 削除と競合してファイルを復活させ得る)

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| gh pr view / auth 解決 | adapters | `lua/review/git/gh.lua` |
| fetch refs/pull、rev-parse | adapters | `lua/review/git/ref.lua` (既存拡張) |
| worktree add/remove/prune/status | adapters | `lua/review/git/worktree.lua` (+ `_spec`) |
| PR セッション開始・worktree 判断 | handlers | `lua/review/handlers/pr.lua`, `lua/review/handlers/session.lua` (拡張) |
| close / delete フロー (確認→save→掃除) | handlers | `lua/review/handlers/session.lua` |
| 実ファイル open (worktree / git show) | ui | `lua/review/ui/fileview.lua` |
| worktree 残骸掃除 | handlers | `lua/review/handlers/health.lua` |

## エッジケースの決定

- gh が未 auth / 非ログイン: `E_GH` 通知。「`gh auth login` を実行してください」。PR 番号だけで repo 内実行時に remote 自動判定失敗時は URL 入力を促す
- 既に同名 worktree がユーザーによって作られている: 触らず衝突エラー (`E_WORKTREE`)。自前作成分以外は削除対象外 (INV-3)
- PR が closed/merged でもレビュー可能 (gh view は成功するため)。開始時に INFO で状態を添えるだけ
- diff 取得後の close 時に worktree 内をユーザーが編集していた: 「セッションは閉じるが編集は残る」ため、実ファイル側は保持 (削除しない) --force 確認で初めて消える。v1 ではこの確認の 1 段階のみ。編集の取り込み (PR への push) は対象外
- 複数 fork remote: refs/pull/N/head を持つ remote を 1 つ選んで fetch (選択不能時にエラー)。head 内容解決は refs/pull ベースなので fork 名に依存しない
- Windows プラットフォーム: worktree 対応とパス区切りは `vim.fs.joinpath` で吸収するが実機検証外 (v1 の検証済みは macOS/Linux のみ。DESIGN.md「既知の制約」参照)

- worktree 実ファイルに LSP が付かない利用者設定がある (root_markers が dir 限定 `.git/` のみ — worktree の `.git` は pointer file)。tcd では救えない。レビュー機能自体は継続 (diff 閲覧・コメントは可)。DESIGN「既知の制約」/ README 注意
- LSP root 解決・spawn cwd と tcd の関係は検証済み (FEASIBILITY tab-local-cwd-lsp-root)。アプリ側の対応コードは tcd と tab 作成のみ

## テスト方針

- 単体 (worktree アダプタ): `gh` と `git` を注入スタブに差し替えて、add/remove/fetch 引数の組み立てと結果型分岐 (成功・失敗・stderr 整形)
- 単体 (handlers/pr): PR メタ→ref 解決→worktree add→diff(cwd=worktree) の呼び出し順と、worktree 作成失敗時の中断分岐。判断表の branch 行が「常に作らない」に変わったことの回帰 (従来「dirty なら作る」を期待する test は新契約の test に置換 — 検出能力ゼロの常時 PASS test にしない)
- 単体 (close フロー): tab 消滅・extmark 残骸 0・modified ユーザーバッファ保持・worktree force 確認 (遅延 remove スタブで順序は既存契約)
- E2E (golden path、gh スタブ + 実 git): fixture repo で `feature` に対する `:Review pr` → worktree 作成・専有 tab・**tab cwd==worktree・head 窓 buf file==worktree 内パス** → head 窓 `c` でコメント → worktree 実ファイルへ編集 `:w` → ±カウント・窓 diff 反映 (diffupdate) → `o` で前行儀 tab に worktree 基準パスの実ファイル → close → worktree dir 消滅 (ref は残る)・tab 消滅 → 別プロセス scan 残骸なし。もう 1 本、異常終了模擬 (close せずプロセス終了 → 次起動 scan 回収 → 復元で worktree 再生成)
