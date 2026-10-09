# pr-worktree (PR レビューと git worktree 連携)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。MUST 4)

## 何を作るか

`gh` CLI で PR を解決し、head を git worktree にチェックアウトした状態でレビューセッションを開始する。**worktree はモード pr のみ** — ブランチレビューは現在のチェックアウトを直接レビューする (DESIGN.md「worktree 作成条件」。head が現在の HEAD と違うときだけ switch 提案 / scratch 縮退、diff-review「head 解決フロー」)。レビューは専有 tab を worktree に `tcd` して開き、head 窓が **worktree 内の実ファイル** になる (編集可・LSP attach)。セッション終了時に worktree とレビュー tab・張った extmark をクリーンアップする。作成・消去のロジックは DESIGN.md「既知の制約」の worktree・crash・fork PR・Windows の各行に従う。

## 入出力と振る舞い

**PR 解決** `:Review pr <number|url>`:

1. url からは PR 番号を抽出 (`/pull/<n>` 末尾)。PR の解決は `gh api graphql` 1 回で行い、number・title・url・state・baseRefName・headRefName・headRepositoryOwner に加えて、GitHub 上の tip 2 つを得る。base ブランチの**現在の** tip (`baseRef.target.oid`) と、PR head の sha (`headRefOid`) である。番号指定は owner/repo を gh の placeholder (`-F owner={owner} -F name={repo}`) に任せ、`gh pr view <n>` と同じ規則で cwd の repo から解決させる。URL 指定は URL の host / owner / repo を `--hostname <host>` と `-f owner=<owner> -f name=<repo>` で明示する (`-F` は型変換するため、数字だけの owner 名がクエリの型エラーになる)。`gh pr view --json baseRefOid` を使わないのは、その値が PR 更新時点の base で、base ブランチの現在の tip ではないため (2026-10-09 実測: PR #53 で merge-base を返し、main の現在の tip と違った)。gh 不在・未 auth・PR 非存在は `E_GH` / `E_PR` を通知する (`state` は closed/merged PR の開始時 INFO 注記に使う)
2. remote の選択と head ref の用意: remote は `git remote` に origin があれば origin、無ければ最初の 1 件を使う。0 件なら «cannot resolve the git remote; run inside the PR target repository, or identify the repository with :Review pr <URL>» を WARN 通知して開始を中断する。head は、同一リポジトリの branch (`<headRefName>` が `rev-parse --verify` で解決できる) ならそのまま使う。それ以外 (fork) は自前一時 ref `review-nvim/pr-<n>` を使い、その sha が `headRefOid` と違う (または ref が無い) ときだけ `git fetch <remote> refs/pull/<n>/head:review-nvim/pr-<n>` で更新する (ref 名は決定的なので次回以降も同じ ref を更新する)
3. base ref の用意: base は**常に** remote-tracking ref `<remote>/<baseRefName>` (例 `origin/main`) とし、ローカル branch の有無・鮮度には依存しない。stacked PR の base はローカル branch に無いことが多く、素の `<baseRefName>` は `git diff` で解決できないため。`refs/remotes/<remote>/<baseRefName>` の sha が base の現在の tip と違う (または ref が無い) ときだけ `git fetch <remote> +refs/heads/<baseRefName>:refs/remotes/<remote>/<baseRefName>` で更新する。base ブランチが GitHub から消えていて tip が得られない (`baseRef` が null) ときは照合せずに fetch し、失敗をそのまま通知する。refspec を明示するのは remote の fetch 設定 (`--single-branch` clone 等) に依存せず更新するためで、`+` は base の force push でも上書きする
   - **fetch は古い ref だけ**: 最新の ref を fetch しても転送が 0 になるだけで、所要時間の大半を占める remote への接続確立は省けない (2026-10-09 実測、ssh remote: `git fetch` 1 回 2.2 s・`--dry-run` でも同じ・`ssh -T git@github.com` 単体 1.6 s)。照合を `git ls-remote` で行わないのも同じ理由である (1 回 2.2 s)。fork PR で head と base の両方が古いときは、2 つの refspec を並べた 1 回の fetch にまとめる
   - **fetch 失敗**: base だけの fetch は «cannot fetch the PR base branch "<baseRefName>" from <remote>: <stderr 主行>»、head だけの fetch は git の stderr 主行、まとめた fetch は «cannot fetch the head and base branch "<baseRefName>" of PR #<n> from <remote>: <stderr 主行>» を WARN 通知する。いずれも開始を中断する (worktree は作らない)
   - **旧形式 base の書き換え**: 同じ slug (`pr-<n>`) の保存済みセッションが base を素の `<baseRefName>` で持ち head が一致する場合は、base を `<remote>/<baseRefName>` に書き換えて save してから開始する (refs 組の一意性は文字列比較なので、書き換えないと同じ PR の再開始が slug 衝突で拒否される)。書き換えは継承確認より前に行うので、確認を拒否しても残る (書き換え後の base は直前に照合・更新した解決可能な ref で、素の `<baseRefName>` はローカル branch が無いと復元時に解決できない)。base が別ブランチ (PR の付け替え) や head 不一致の既存は書き換えず、slug 衝突を案内する
4. base/head (base は手順 3 の remote-tracking ref、head はブランチ名 / fork なら fetch した一時 ref) で **worktree を作成 (add) してから**、`git diff <base>` (cwd=worktree、**作業ツリー基準**) を取得 → 以降 diff-review と同じ UI を開く (tab は作成済み worktree に `:tcd`。PR タイトルは開始時に INFO 通知するだけ。セッションには永続化しない)

**worktree 作成判断** — 作成するのはモード pr のみ。「レビュー対象の状態」を worktree の実ファイルとして成立させるための規則 (DESIGN.md 決定表と同一):

| 条件 | worktree |
| --- | --- |
| mode=branch | **作らない**。現在のチェックアウトを直接レビューする。head が現在の HEAD と違う場合のみ switch 提案 or scratch 縮退で対応し、worktree で回避しない (diff-review「head 解決フロー」。head が作業ツリー基準になった今、別ツリーで commit 内容を見せる意味がない) |
| mode=pr | `git worktree add --detach <path> <head>` (path = `stdpath("data")/review.nvim/worktrees/<repo-hash>/<slug>`)。**`--detach` を使うので branch checkout と競合しない**。slug は repo 単位にしか一意でないため `<repo-hash>` 下で分離する (別 repo の同一 slug が同 path で衝突するのを防ぐ) |
| PR かつ head が fork 由来 (同一 repo に headRefName の branch が無い) | 上記に先立ち `git fetch <remote> refs/pull/<n>/head` で `review-nvim/pr-<n>` ref を作り、それを `<head>` として worktree を作成 |

作成失敗 (パス衝突) は既存同名ディレクトリを `git worktree prune` で回収試行 → 改善しなければ `E_WORKTREE` 通知で開始を中断。**衝突した残骸が自分の作成分 (`created_by_us=true` の記録あり) でない限り自動削除しない** (INV-3)。

**段階別の過渡メッセージ**: 開始 (`:Review pr` / `:Review start`) と復元は UI が開くまで数秒かかりうるので、いま走っている段階をメッセージエリアに INFO で表示し、段階が終わるたびに消す (`lua/review/handlers/progress.lua`)。段階と文言は次のとおり。

| 段階 | 文言 | 出る条件 |
| --- | --- | --- |
| PR 解決 (`gh api graphql`) | «resolving PR #<n>...» | `:Review pr` |
| base の fetch | «fetching <remote>/<baseRefName>...» | base だけが古い |
| fork head の fetch | «fetching the head of PR #<n> from <remote>...» | pull ref だけが古い |
| まとめた fetch | «fetching the head of PR #<n> and <remote>/<baseRefName>...» | 両方が古い |
| worktree 作成 | «creating the review worktree...» | mode=pr で `git worktree add` するとき |
| 差分取得 | «loading the diff...» | 開始・復元の全モード |

- 同時に走る段階が複数あれば、開始順に `, ` で 1 行に併記する (例 «review.nvim: A, B...»)
- 消すのは全終了経路 (成功 / 失敗 / キャンセル) で、失敗の WARN は段階を消した**後**に出す。メッセージエリアに段階文言が残ったまま WARN や継承確認の [y/N] を重ねないため
- 既定の `vim.notify` は echo のみで id 指定の非表示が無いため、消去は全段階が終わった時点の `nvim_echo({}, false, {})` で行う。カスタム notify プロバイダ向けの `{hide=id}` は使わない

**0 差分・差分取得失敗時の掃除 (開始 / 復元)**: pr 開始で差分 0 ファイルなら «No changes» INFO で開かず save しないが、作成は diff に先行するので作りたて／再利用の自前 worktree を `git worktree remove --force` で掃除する (**close / delete と同じ直列化 lock 下**。失敗は WARN で記録は残し、起動 scan が回収できる状態を保つ)。`--force` を付けるのは、一段目が失敗しても二段目 (`git worktree prune` + 自前 dir 再帰削除) が dirty でも無条件に dir を消す契約で、force 無しは安全性を足さないため。利用者の post-checkout hook が worktree 作成時に tracked ファイルを書き換える repo (依存 install が生成物を上書きする等) では、force 無しの remove が必ず拒否されて WARN と prunable な登録残骸が残る。確認付きで消すのは delete 側だけである。既存保存セッションの記録を再利用 (旧記録と同じ path の作成分を含む) していた場合は、掃除成功後にそのセッション JSON の worktree 記録を nil 化して save する (実在しない dir を指した記録を残さない。comments / refs / status はそのまま。nil 化 save は直前にディスク上の JSON 存在を再確認し、掃除の窓中に :Review delete が完了していたら復活させない — persistence-restore「存在再確認」)。nil 化の対象も自前記録のみ (`created_by_us=true` かつ同 path。legacy の非自前記録を黙って消さない)。**diff 取得が失敗した場合も同じ掃除を走る** (開始 / 復元どちらの経路も `fetch_prepared` の diff 失敗分岐。放置すると作りたて worktree が記録なしの孤児になる)。掃除が remove・prune+dir 削除とも失敗したとき、その dir を指す created_by_us 記録が JSON に残らない場合は「起動 scan が回収」ではなく**手動削除を案内する WARN を出す** (INV-3: 記録のない dir を scan は触れないため、回収を約束しない)。

**head 窓と実ファイル (`o`)**:

- head 窓そのものが worktree 実ファイル (`:edit`、編集可・LSP attach)。レビュー中の編集は保存でリフレッシュされ、差分・カウント・prompt に反映される (diff-review「リフレッシュ (未コミット反映契約)」)
- 旧 `o` (前行儀 tab に実ファイルを開く導線) は 2026-09 削除。head 窓自体が worktree 実ファイル (`:edit`) に変わったため不要 (導線の二重化を解消)
- head 窓で編集した内容はセッション保存対象ではない (保存されるのは comments / viewed / refs のみ。編集がディスクにある限り復元後のレビュー内容に現れる — branch/PR 共通、DESIGN 不変条件 INV-4)
- レビュー対象のファイルそのものが無い (削除ファイル) head 窓は告知 scratch のみで編集不可。base 窓側の削除前コンテンツは読める

**セッションとレビューの終了 (`:Review close` / `q`)** — 順序の原則: ユーザーデータを失いうる操作の判定と確認を、状態変更より前に行う (`q` と `:Review close` は同一経路):

0. comments > 0 なら «close the session with N comments (%s)?» [y/N] (キャンセル = 終了を最初から中止)。0 件なら確認しない
1. 現セッションを save して status=closed、active を解除、**レビュー専有 tab を閉じる**。閉じる前に、このセッションが張った全バッファ (head 実ファイル・scratch) の extmark namespace を明示 clear (残骸 0)。repo 本体の実ファイルバッファはユーザーの所有物なので編集途中 (modified) を含め消さずに窓だけ閉じる
2. **worktree は削除しない** — close は save + UI 掃除のみで完結する。worktree dir・未コミット変更・未保存バッファはすべて残り、再レビュー時 (再開 / 同 refs の再開始) は作成済み worktree を再利用する。したがって close に status 検知や `--force` 確認は無い (削除しないので)。**worktree の削除は `:Review delete` / セッション一覧 `d` のみ**
3. 自前 ref (`review-nvim/pr-<n>`) も close では消さない (再開時に PR head が変わっていなければ fetch を省略して再利用するため)

**worktree 登録操作の直列化**: 同じ dir path に対する `git worktree remove` (delete / 開始時の 0 差分掃除、掃除失敗時の prune 二段目を含む) と `git worktree add` (start / resume の作成判断〜作成) は、セッション内で 1 本ずつ直列に実行する。remove は管理登録の解除 + ツリー削除の重い git I/O で、その最中に同じ path へ add すると remove の中間状態を跨いで再登録となり、git が衝突しない管理名 (`main--issue-4` + `main--issue-41` の形) で同一 dir を二重登録することがある (以後の remove が "does not point back" で失敗し続け、削除するたびに WARN が出る実測状態の源)。add 側は読み取り (diff 取得など) を待たず、**登録を作る経路 (resolve_worktree の判断〜作成〜完了、remove 連鎖の完了) だけが待機する**。close は worktree を削除しないため、このレースは delete の remove と後続の start の add の間でのみ起こる

**セッションの削除 (`:Review delete <id>`)**: 入力時に確認 (`コメント N 件を削除します`)。active と同じ id なら close (save + UI 掃除のみ。worktree は残る) を先に実行してから、自前 worktree を掃除する: `git -C <worktree-path> status --porcelain` で dirty 判定 (git status に加えて worktree 配下の modified バッファも見る。どちらかあれば `--force` 確認。キャンセル = delete 中止・JSON 保持) → `git worktree remove <path>` (承認済みなら `--force`) → 失敗時は `git worktree prune` + 自前 dir 再帰削除で回収。掃除が完遂できない場合は孤児 dir を残さないため JSON を残して中止 (closed + created_by_us 記録として起動 scan が回収できる状態を保つ)。掃除完了後にセッション JSON ファイルを削除し、このセッション用に作った `review-nvim/pr-<n>` ref があれば消す。closed でも `created_by_us=true` の worktree は close が残す設計なので通常ここに残っており、同一の掃除をしてからファイルを削除する。削除は不可逆で、undo は提供しない。

**異常終了からの回復 (起動 scan、persistence-restore の scan を利用)**:

- 記録上 open のセッションについて worktree path の実在を確認。実在して repo の `git worktree list` に載っていればそのまま復元で再利用する (crash 後でも worktree は使える)。記録にあるのにディレクトリが消えていれば worktree=null にして save し、復元時の作成判断 (persistence-restore「復元手順」) で作り直す
- `created_by_us=true` の worktree のうち、**open で dir 実在 + git 未登録 (孤児の作成分)** を通知付きで掃除する (`git worktree prune` + ディレクトリ削除。記録は nil 化して save = 復元時の再生成へ渡す)。dir を消す全経路の契約どおり、dir 削除より先に worktree 配下を指す loaded バッファを `nvim_buf_delete(force)` で破棄する (ユーザーが `:edit` 等で見ている分も含む — E211 対策)
- **closed + dir 実在の worktree は scan が触らない** — close は worktree を残す設計なので closed の dir は正常状態。削除は `:Review delete` / セッション一覧 `d` のみ (close 時の削除競合による JSON 復活事故も、closed を掃除しなくなったことで経路ごと消える)

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| PR 解決 (`gh api graphql`、remote tip 込み) / auth 判定 | adapters | `lua/review/git/gh.lua` |
| fetch refs/pull・base・両方まとめた fetch、rev-parse | adapters | `lua/review/git/ref.lua` (既存拡張) |
| worktree add/remove/prune/status | adapters | `lua/review/git/worktree.lua` (+ `_spec`) |
| PR セッション開始・worktree 判断 | handlers | `lua/review/handlers/pr.lua`, `lua/review/handlers/session.lua` (拡張) |
| close / delete フロー (確認→save→掃除) | handlers | `lua/review/handlers/session.lua` |
| 実ファイル open (worktree / git show) | — | 廃止 (`ui/fileview.lua` 削除。head 窓が実ファイル) |
| worktree 残骸掃除 | handlers | `lua/review/handlers/health.lua` |
| 段階別の過渡メッセージ | handlers | `lua/review/handlers/progress.lua` |

## エッジケースの決定

- gh が未 auth / 非ログイン: `E_GH` 通知。「`gh auth login` を実行してください」。PR 番号だけで repo 内実行時に remote 自動判定失敗時は URL 入力を促す
- 既に同名 worktree がユーザーによって作られている: 触らず衝突エラー (`E_WORKTREE`)。自前作成分以外は削除対象外 (INV-3)
- PR が closed/merged でもレビュー可能 (PR の解決は成功するため)。開始時に INFO で状態を添えるだけ。merge 後に base ブランチが消えた PR は base の tip が得られないので照合せず fetch し、失敗は base の fetch 失敗として通知して中断する
- worktree 内をユーザーが編集していても close は何も捨てない (worktree を残すため。dirty 判定も確認も不要)。編集を破棄して消すのは `:Review delete` のときだけで、dirty 判定はディスク (`git status`) に加えて worktree 配下の modified バッファも見る (バッファ上の未保存編集はディスクに無いため git status は clean を返す)。どちらかがあれば `--force` 確認を 1 回出し、承認したときだけ消える (ディスクの未コミット変更もバッファ上の未保存編集も破棄)。キャンセルは delete 全体の中止。v1 ではこの確認の 1 段階のみ。編集の取り込み (PR への push) は対象外
- 複数 fork remote: refs/pull/N/head を持つ remote を 1 つ選んで fetch (選択不能時にエラー)。head 内容解決は refs/pull ベースなので fork 名に依存しない
- Windows プラットフォーム: worktree 対応とパス区切りは `vim.fs.joinpath` で吸収するが実機検証外 (v1 の検証済みは macOS/Linux のみ。DESIGN.md「既知の制約」参照)

- worktree 実ファイルに LSP が付かない利用者設定がある (root_markers が dir 限定 `.git/` のみ — worktree の `.git` は pointer file)。tcd では救えない。レビュー機能自体は継続 (diff 閲覧・コメントは可)。DESIGN「既知の制約」/ README 注意
- LSP root 解決・spawn cwd と tcd の関係は検証済み (FEASIBILITY tab-local-cwd-lsp-root)。アプリ側の対応コードは tcd と tab 作成のみ

## テスト方針

- 単体 (worktree アダプタ): `gh` と `git` を注入スタブに差し替えて、add/remove/fetch 引数の組み立てと結果型分岐 (成功・失敗・stderr 整形)
- 単体 (handlers/pr): PR メタ (remote tip 込み)→remote 選択→base / head の ref と remote tip の照合→古い ref だけの fetch→worktree add→diff(cwd=worktree) の呼び出し順と、照合結果ごとの fetch の有無 (なし / base のみ / head のみ / まとめて 1 回)、fetch・worktree 作成失敗時の中断分岐、段階別の過渡メッセージの並び。判断表の branch 行が「常に作らない」に変わったことの回帰 (従来「dirty なら作る」を期待する test は新契約の test に置換 — 検出能力ゼロの常時 PASS test にしない)
- 単体 (close フロー): tab 消滅・extmark 残骸 0・modified ユーザーバッファ保持・**close は worktree を残す (remove / status / force 確認を一切呼ばない)**。delete フロー: status → (dirty なら) --force 確認 → remove → 失敗時 prune + dir 削除の順序
- E2E (golden path、gh スタブ + 実 git): gh スタブは `api graphql` に fixture JSON を返し、その tip には fixture repo の実 sha を埋める (clone 直後の base は最新で fetch を省き、未取得の pull ref だけを fetch する状態)。fixture repo で `feature` に対する `:Review pr` → worktree 作成・専有 tab・**tab cwd==worktree・head 窓 buf file==worktree 内パス** → head 窓 `c` でコメント → worktree 実ファイルへ編集 `:w` → ±カウント・窓 diff 反映 (diffupdate) → `o` で前行儀 tab に worktree 基準パスの実ファイル → close → **status=closed で worktree dir は残る (keep。ref も残る)**・tab 消滅 → 別プロセス scan 無通知 (closed は keep)。もう 1 本、異常終了模擬 (close せずプロセス終了 → 次起動 scan 回収 → 復元で worktree 再生成)。worktree を編集して dirty のまま delete → --force 確認の cancel / approve を実 git で pin
