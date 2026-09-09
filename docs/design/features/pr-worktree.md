# pr-worktree (PR レビューと git worktree 連携)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。MUST 3)

## 何を作るか

`gh` CLI で PR を解決し、head を git worktree にチェックアウトした状態でレビューセッションを開始する (ブランチレビューでも worktree 作成判断の例外条件に当たらない限り同じ仕組みで作る — DESIGN.md「アーキテクチャと技術選定」worktree 作成条件)。レビュー中は diff 上の `o` で worktree 内の実ファイルを開け、セッション終了時に worktree をクリーンアップする。作成・消去のロジックは DESIGN.md「既知の制約」の worktree・crash・fork PR・Windows の各行に従う。

## 入出力と振る舞い

**PR 解決** `:Review pr <number|url>`:

1. url からは PR 番号を抽出 (`/pull/<n>` 末尾)。番号解決は `gh pr view <n|url> --json number,title,baseRefName,headRefName,headRepositoryOwner,url,state` を実行。gh 不在・未 auth・PR 非存在は `E_GH` / `E_PR` を通知 (`state` は closed/merged PR の開始時 INFO 注記に使う。#6 実装で追加)
2. head ref の用意: 同一リポジトリの branch なら `<headRefName>` をそのまま使い、それ以外 (fork) は `git fetch <remote> refs/pull/<n>/head:review-nvim/pr-<n>` を実行 (ref 名は決定的なので次回以降 fetch で上更新可)。remote 選択は default remote に無ければ origin で試す
3. base/head (ブランチ名 / fetch した一時 ref) で diff を取得し、worktree 作成判断に従って作成 → 以降 diff-review と同じ UI を開く (PR タイトルは開始時に INFO 通知するだけ。セッションには永続化しない)

**worktree 作成判断 (ブランチ・PR 共通)** — 「`@path` が指すファイルは読める実ファイル (= head のコミット内容)」を常に成立させるための規則 (DESIGN.md 決定表と同一):

| 条件 | worktree |
| --- | --- |
| mode=branch かつ `git rev-parse <head>` のコミットが現在の HEAD と一致し、かつ `git status --porcelain` が空 | 作らない (現在の作業ツリーが head の実ファイルそのもの) |
| それ以外 (head ≠ HEAD のコミット、未コミット変更あり、mode=pr) | `git worktree add --detach <path> <head>` (path = `stdpath("data")/review.nvim/worktrees/<repo-hash>/<slug>`)。**`--detach` を使うので branch checkout と競合しない**。slug は repo 単位にしか一意でないため `<repo-hash>` 下で分離する (#6 実装で確定。別 repo の同一 slug が同 path で衝突するのを防ぐ) |
| PR かつ head が fork 由来 (同一 repo に headRefName の branch が無い) | 上記に先立ち `git fetch <remote> refs/pull/<n>/head` で `review-nvim/pr-<n>` ref を作り、それを `<head>` として worktree を作成 |

作成失敗 (パス衝突) は既存同名ディレクトリを `git worktree prune` で回収試行 → 改善しなければ `E_WORKTREE` 通知で開始を中断。**衝突した残骸が自分の作成分 (`created_by_us=true` の記録あり) でない限り自動削除しない** (INV-3)。

**実ファイル参照** (diff・sidebar の `o`):

- worktree あり → 対象パスを worktree 基準 (`<worktree>/<file>`) で `:e` のように開く (編集可)。編集された内容はそのまま review に反映されない (diff は base..head の committed diff のまま — 実ファイル編集は AI への input 準備であってレビュー対象の変更ではない)
- worktree なし → `git show <head>:<path>` の read-only scratch バッファを開く
- diff のその行が new 側に無い (削除行) → コンテキストへ寄せずに WARN

**セッションとレビューの終了 (`:Review close` / `q`)** — 順序の原則: ユーザーデータを失いうる操作の判定と確認を、状態変更より前に行う:

1. worktree 作成済みなら `git -C <worktree-path> status --porcelain` で未コミット変更を検知。変更ありなら `--force` で削除してよいか確認 (キャンセル = **close を最初から中止**。セッション・UI・保存状態は何も変わらない)。変更なしなら確認不要で続行
2. 現セッションを save して status=closed、active を解除、UI 窓を閉じる (コメント保持。`:Review` / list で再開可)
3. worktree を `git worktree remove <path>` (1 で force 承認済みなら `--force`) で削除。**自前 ref (`review-nvim/pr-<n>`) は close では消さない** (再開時に fetch を省略して再利用するため)
4. 掃除失敗 (`remove` の失敗等) は WARN を出し、close (save・クローズ) 自体は完了させる。残骸は起動 scan が closed + dir 残骸として回収する

**セッションの削除 (`:Review delete <id>`)**: 入力時に確認 (`コメント N 件を削除します`)。active と同じ id なら close の 1〜3 を先に実行してから、セッション JSON ファイルを削除し、このセッション用に作った `review-nvim/pr-<n>` ref があれば消す。closed でも `created_by_us=true` の worktree 残骸 (close の掃除失敗経路で発生しうる) があれば close の 3〜4 と同等の掃除を行ってからファイルを削除する (孤児 dir を残さない)。削除は不可逆で、undo は提供しない。

**異常終了からの回復 (起動 scan、persistence-restore の scan を利用)**:

- 記録上 open のセッションについて worktree path の実在を確認。実在して repo の `git worktree list` に載っていればそのまま復元で再利用する (crash 後でも worktree は使える)。記録にあるのにディレクトリが消えていれば worktree=null にして save し、復元時の作成判断 (persistence-restore「復元手順」) で作り直す
- `created_by_us=true` の worktree のうち、セッション側が closed なのにディレクトリが残っている残骸を「掃除してよい残骸」として通知し、`git worktree prune` + ディレクトリ削除で回収する。**closed の掃除ではセッションファイルを書き戻さない** (dir 消滅後の記録は以後 scan に出ないため放置で無害。書き戻しは `:Review delete` の JSON 削除と競合してファイルを復活させ得る — #6 E2E で検出)

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

## テスト方針

- 単体 (worktree アダプタ): `gh` と `git` を注入スタブに差し替えて、add/remove/fetch 引数の組み立てと結果型分岐 (成功・失敗・stderr 整形)
- 単体 (handlers/pr): PR メタ→ref 解決→diff→worktree 判断表の各分岐 (同一ブランチ / 別ブランチ / fork ref)
- E2E (golden path、gh スタブ + 実 git): fixture repo で `feature` に対する worktree を持つセッション開始 → diff 上の `o` で worktree 内のファイルが開き、内容が head の実物と一致 → close → worktree ディレクトリが消える (ref は残る) → 別プロセス起動後に残骸 scan が出ないことを assert。もう 1 本、異常終了の模擬として「close せず nvim プロセスを終了 → 次起動 scan で残骸回収通知 → 復元時に worktree が再生成される」を追加
