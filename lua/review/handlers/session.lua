-- セッション開始・切替・終了・削除の調整役 (docs/design/features/diff-review.md
-- 「開始」「レイアウト (専有 tabpage 3 窓)」「head / base 窓の中身」「open_file」
-- 「コメント表示」「review tab の消滅経路」「開始と既存セッションの継承」/
-- persistence-restore.md「復元手順」共通部 / pr-worktree.md「worktree 作成判断」
-- 「セッションとレビューの終了」「セッションの削除」)。
-- 契約の要点:
--   * 戻り値は同期に判定できる失敗のみ (git を伴う成否は notify / UI で返す)
--   * INV-1: active セッションは高々 1 つ。切替は必ず save -> close を経る
--   * INV-3: worktree を削除してよいのは created_by_us=true の記録のある分だけ
--   * INV-4: CRUD・viewed 切替の効果直後に store.save
--   * レイアウトは ui/windows、scratch buffer は ui/scratchwin、窓 role gate と
--     キーは ui/keygate、コメント extmark は ui/commentmarks。この層は「どの
--     バッファをどちらの窓に張るか」の解決と保存だけを持つ (open_file = 移動系
--     の唯一経路)。
--   * 行写像は恒等: コメントの new 側行番号 = head バッファ (実ファイル /
--     縮退 head scratch) の行番号そのもの (INV-2。unified 行写像は廃止)。
local git_diff = require 'review.git.diff'
local git_ref = require 'review.git.ref'
local git_repo = require 'review.git.repo'
local git_worktree = require 'review.git.worktree'
local paths = require 'review.store.paths'
local anchor = require 'review.core.anchor'
local result = require 'review.core.result'
local store = require 'review.store.session'
local ui_chrome = require 'review.ui.chrome'
local ui_commentmarks = require 'review.ui.commentmarks'
local ui_fileview = require 'review.ui.fileview'
local ui_keygate = require 'review.ui.keygate'
local ui_filepanel = require 'review.ui.filepanel'
local ui_treelist = require 'review.ui.treelist'
local ui_scratchwin = require 'review.ui.scratchwin'
local ui_windows = require 'review.ui.windows'
local usermsg = require 'review.handlers.usermsg'

local M = {}

local now = os.time

function M._set_now(fn)
  now = fn or os.time
end

-- 差分がまるごと消えた開通の情報プレースホルダ path (diff-review「セッション開始時の
-- 初期開き」: open_file の代わりに「変更なし」scratch を base/head 窓へ張り、
-- outdated 集約もそこへ出す)。
M.NO_CHANGES = '(no-changes)'

-- active = { session, files_by_path, file_order, file_order_sorted, panel_buf,
--            current = { path, file, kind, base_buf, head_buf }, degraded,
--            fill_token, owned_bufs = { [bufnr]=true }, scratch_bufs = {} }
local active = nil
-- file panel の view state (session JSON に載せない — diff-review「file panel」)。
-- filter: 絞り込み句。panel_mode: 'tree' (既定) ⇄ 'list' (`i`)。panel_collapsed:
-- 折り畳んだ dir の集合 (key = row_entry の deepest dir path)。
local sidebar_filter = nil
local panel_mode = 'tree'
local panel_collapsed = {}

local function reset_panel_view_state()
  sidebar_filter = nil
  panel_mode = 'tree'
  panel_collapsed = {}
end

-- リフレッシュ in-flight まとめ (diff-review「リフレッシュ」): git diff 同時 1 本。
-- in-flight 中は二重発火せず dirty マークだけ立て、完了後に追い fetch 1 回。
-- close / 切替 (detach) で active とともに無効化する。
local refresh_inflight = false
local refresh_dirty = false

local function reset_refresh_state()
  refresh_inflight = false
  refresh_dirty = false
end

--forward decl (循環: UI <-> 開始手続き)
local begin_session
local open_session_ui

function M._reset()
  active = nil
  reset_panel_view_state()
  reset_refresh_state()
  ui_windows.reset()
end

--- 起動中のセッション (UI が開いているもの)。無ければ nil (INV-1 で高々 1)。
function M.active()
  return active and active.session or nil
end

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

-- worktree 登録変更の直列化 (close -> 即 start 競合の是正)。
-- q close の `git worktree remove` (管理登録の解除 + ツリー削除 = 重い git I/O)
-- の最中に同じ path へ `git worktree add` を実行すると、remove の中間状態
-- (登録は外れたが dir は半分残る) を跨いで再登録になり、git が衝突しない管理名
-- (`main--issue-4` + `main--issue-41`) で同一 dir を二重登録する。以後の remove
-- が "does not point back" で失敗し続ける実測状態の源。同一 dir path では
-- remove/add 連鎖を直列に 1 本だけ走らせる (ロック保持側が全終了経路で
-- wt_unlock を呼ぶ責務)。
local wt_lock_q = {}

local function wt_with_lock(path, fn)
  local q = wt_lock_q[path]
  if q ~= nil then
    q[#q + 1] = fn
    return
  end
  wt_lock_q[path] = {}
  fn()
end

local function wt_unlock(path)
  local q = wt_lock_q[path]
  if q == nil then
    return
  end
  wt_lock_q[path] = nil
  for i = 1, #q do
    wt_with_lock(path, q[i])
  end
end

-- remove 失敗後の二段目 (delete 側 sweep と共通の正攻): 崩れた自己登録は prune
-- が直し、dir は再帰削除で消す (git 自身の手順)。close 側は dir 残りを理由に
-- 終了を中断しないので成否に関わらず完了コールへ進む。
local function prune_and_rm_dir(repo, path, done)
  git_worktree.prune({ repo = repo }, function()
    if not git_worktree.remove_dir(path) then
      notify_warn(
        ('worktree dir を削除できませんでした (起動 scan / :Review delete が回収します): %s'):format(
          path
        )
      )
    end
    done()
  end)
end

-- [y/N] の確認。vim.ui.input を使う (vim.fn.confirm は headless で絞込めない)。
local function confirm(prompt, cb)
  vim.ui.input({ prompt = prompt }, function(answer)
    cb(answer == 'y')
  end)
end

local function dir_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

-- JSON round-trip 済みの worktree 記録テーブル (無ければ nil)。
-- (vim.NIL / nil / 非 table を まとめて無記録に潰す)
local function worktree_of(session)
  local wt = session.worktree
  if wt == nil or wt == vim.NIL or type(wt) ~= 'table' then
    return nil
  end
  return wt
end

local function owned_worktree(session)
  local wt = worktree_of(session)
  return wt ~= nil and wt.created_by_us == true
end

-- close / delete / 開始時の掃除で使う単一の --force 確認文。
local function force_prompt(path)
  return (
    'review.nvim: worktree %s に未コミットの変更があります。削除して閉じますか？ '
    .. '(git worktree remove --force — ディスクの編集は破棄されます) [y/N]: '
  ):format(path)
end

-- ============================================================================
-- worktree 作成判断 (pr-worktree.md 決定表)
-- ============================================================================

-- 作成するのは mode=pr のみ。branch は現在のチェックアウト (作業ツリー) を
-- 直接レビューし、head が現在の HEAD と違うときは worktree で回避せずに
-- switch 提案 / scratch 縮退で対応する (diff-review「開始」2、DESIGN 決定表
-- 「worktree 作成条件」)。branch で created_by_us 記録が残っている分
-- (旧契約の名残) は作成スキップ時の掃除 (cleanup_skipped_record) で回収する。
local function creation_needed(args)
  return args.mode == 'pr'
end

-- add -> (衝突時) prune 再試行 -> (自前記録あり) dir 削除して再々試行。
-- 「衝突した残骸が自前作成分でない限り自動削除しない」(INV-3 / pr-worktree.md)。
local function add_with_recovery(args, path, record, cb)
  local function add(reason_cb)
    git_worktree.add({ repo = args.repo, path = path, ref = args.head }, reason_cb)
  end
  add(function(res)
    if res.ok then
      cb(result.ok { path = path, created_by_us = true })
      return
    end
    local first_err = res
    git_worktree.prune({ repo = args.repo }, function()
      add(function(res2)
        if res2.ok then
          cb(result.ok { path = path, created_by_us = true })
          return
        end
        if record ~= nil and record.created_by_us == true then
          git_worktree.remove_dir(path)
          add(function(res3)
            if res3.ok then
              cb(result.ok { path = path, created_by_us = true })
              return
            end
            cb(result.err(res3.error, result.codes.E_WORKTREE))
          end)
          return
        end
        cb(
          result.err(
            (
              'worktree を作成できません: %s。同名の作業ツリーが残っている場合は '
              .. '`git worktree remove` で掃除してから再試行してください (%s)'
            ):format(path, first_err.error),
            result.codes.E_WORKTREE
          )
        )
      end)
    end)
  end)
end

-- 判断スキップ時にも自前 worktree dir が残っていた場合の掃除 (放置すると
-- 次回以降の同 path add が衝突し、記録も無い状態では回復できないため)。
-- 未コミット変更があれば確認し、キャンセルは E_CANCELLED (ユーザー操作、無通知)。
local function cleanup_skipped_record(record, cb)
  git_worktree.status({ repo = record.repo, path = record.path }, function(res)
    if not res.ok then
      cb(result.ok(vim.NIL)) -- dir 消失 etc: 触るものなし
      return
    end
    local function finish(force)
      git_worktree.remove({ repo = record.repo, path = record.path, force = force }, function(rres)
        if not rres.ok then
          notify_warn(
            ('worktree 掃除に失敗しました (残骸は起動 scan が回収します): %s'):format(
              rres.error
            )
          )
          -- resolve_worktree の lock 下なので prune+dir 削除も同じ lock 内で続ける
          prune_and_rm_dir(record.repo, record.path, function()
            cb(result.ok(vim.NIL))
          end)
          return
        end
        cb(result.ok(vim.NIL))
      end)
    end
    if res.data.dirty then
      confirm(force_prompt(record.path), function(yes)
        if yes then
          finish(true)
        else
          cb(result.err('キャンセルされました', result.codes.E_CANCELLED))
        end
      end)
      return
    end
    finish(false)
  end)
end

--- 作成判断〜add〜cb まで (M.resolve_worktree が lock を持つ)。
local function resolve_locked(args, cb)
  -- record は nil | vim.NIL | JSON round-trip 済み table のどれでも飛んでくる
  -- (restore は session.worktree をそのまま渡す)。vim.NIL を table として
  -- index しないようここで正規化する。
  local record = args.record
  if record == nil or record == vim.NIL or type(record) ~= 'table' then
    record = nil
  end
  if not creation_needed(args) then
    if record ~= nil and record.created_by_us == true and dir_exists(record.path) then
      cleanup_skipped_record({ repo = args.repo, path = record.path }, cb)
      return
    end
    cb(result.ok(vim.NIL))
    return
  end
  local path = paths.worktree_path(args.repo, args.id)
  if
    record ~= nil
    and record.created_by_us == true
    and record.path == path
    and dir_exists(path)
  then
    -- 既存 dir 実在 + git 登録済み => 復元でそのまま再利用 (pr-worktree.md 異常終了回復)。
    -- list 不能は再利用不可 (= 作成手順側で衝突案内になり、実データを壊さない)。
    git_worktree.list({ repo = args.repo }, function(res)
      local real = vim.uv.fs_realpath(path)
      if res.ok and real ~= nil then
        for _, p in ipairs(res.data) do
          if (vim.uv.fs_realpath(p) or p) == real then
            cb(result.ok(record))
            return
          end
        end
      end
      add_with_recovery(args, path, record, cb)
    end)
    return
  end
  add_with_recovery(args, path, record, cb)
end

--- args = { repo, id, mode, head, record? } -> cb(result)。
--- result.data = worktree 記録テーブル | vim.NIL (作らない)。
--- 失敗 (E_WORKTREE / E_CANCELLED) は呼び出し側が通知して開始を中断する。
--- 同一 dir path の remove/add 競合を避けるため worktree lock を取得する
--- (作成〜cb 完了まで lock 下。branch の名残掃除も同じ lock 内で走る)。
function M.resolve_worktree(args, cb)
  local lock_path = paths.worktree_path(args.repo, args.id)
  wt_with_lock(lock_path, function()
    local released = false
    local function done(res)
      if not released then
        released = true
        wt_unlock(lock_path)
      end
      cb(res)
    end
    resolve_locked(args, done)
  end)
end

local function persist()
  local res = store.save(active.session)
  if not res.ok then
    -- INV-4 の留保: メモリ上の状態は保ち WARN。次の save 時に再挑戦する。
    notify_warn(res.error)
  end
end

local function close_buffer(bufnr)
  if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

-- レビューが所有するバッファを掃除して active を外す (save しない。close/delete
-- 経路用)。head の実ファイルバッファはユーザーの所有物 — 開いたままのもの
-- (modified を含む) は消さない (diff-review「review tab の消滅経路」)。review://*
-- (panel / base / head 縮退 scratch / null / 告知 / fileview) はここで消す。
-- extmark / キーマップはこの時点で張った全バッファから除く (残骸 0 契約)。
local function detach()
  if active == nil then
    return
  end
  local current = active
  active = nil
  reset_panel_view_state()
  -- close / 切替時の in-flight・dirty 無効化 (リフレッシュ契約)。解決済み
  -- コールバック側の破棄は active 同一性比較 (refresh の guard) が担う。
  reset_refresh_state()
  ui_commentmarks.clear_tracked()
  for buf in pairs(current.owned_bufs) do
    ui_keygate.uninstall(buf)
  end
  ui_windows.close()
  for _, buf in ipairs(current.scratch_bufs) do
    close_buffer(buf)
  end
  close_buffer(current.panel_buf)
end

-- remove 失敗時の二段目: 自前 dir を prune + 再帰削除で消す。それでも残るなら
-- 孤児 dir を残さないためセッション削除を中止する (呼び出し側は JSON を消さず
-- closed + created_by_us の記録を残すので、起動 scan が回収できる)。delete の
-- active 同一 id / closed 残骸の両経路で共有する (pr-worktree.md「セッションの削除」)。
local function sweep_or_abort(repo, path, finalize)
  git_worktree.prune({ repo = repo }, function()
    if git_worktree.remove_dir(path) then
      finalize()
      return
    end
    notify_warn(
      (
        '孤児 worktree dir を消去できませんでした。'
        .. '孤児 dir を残さないためセッション削除は中止します: %s'
      ):format(path)
    )
  end)
end

-- 終了手順の 2〜4 (pr-worktree.md「セッションとレビューの終了」):
-- save(closed) -> active 解除/UI クローズ -> worktree remove (1 の force 承認済なら
-- --force)。掃除の失敗は WARN のみで close 完了 (残骸は起動 scan / delete が回収)。
-- 自前 ref (review-nvim/pr-<n>) は close では消さない (再開時の fetch 省略用)。
-- cb は save + detach 完了後 (状態変更が終わった時点) に呼ばれる。切替・復元は
-- 別 slug の別 path なので remove 完了を待たずに次の操作へ進んで無害。
-- delete の active 同一 id 経路は JSON+ref 削除を手順 3 の完了後へ回すため、
-- after_remove を remove 完了コールバック (skip / 失敗分岐含む) から呼ぶ。
-- vim.system は非同期なのでこれを待たないと削除が remove より先へ進み、remove
-- 失敗時に孤児 dir へ scan が触れなくなる (削除済み JSON の created_by_us を
-- 読めない — pr-worktree.md「セッションの削除」手順 1〜3)。
local function finish_close(current, force, skip_remove, cb, after_remove)
  current.session.status = 'closed'
  local res = store.save(current.session)
  detach()
  if not res.ok then
    notify_warn(res.error)
  end
  if cb ~= nil then
    cb()
  end
  local wt = worktree_of(current.session)
  local function finish_after_remove()
    if after_remove ~= nil then
      after_remove()
    end
  end
  if skip_remove or wt == nil or wt.created_by_us ~= true then
    finish_after_remove()
    return -- INV-3: created_by_us=true の自前作成分のみ削除対象
  end
  wt_with_lock(wt.path, function()
    git_worktree.remove({
      repo = current.session.repo,
      path = wt.path,
      force = force or nil,
    }, function(rres)
      if not rres.ok then
        notify_warn(
          ('worktree 掃除に失敗しました (残骸は起動 scan が回収します): %s'):format(
            rres.error
          )
        )
        prune_and_rm_dir(current.session.repo, wt.path, function()
          wt_unlock(wt.path)
          finish_after_remove()
        end)
        return
      end
      wt_unlock(wt.path)
      finish_after_remove()
    end)
  end)
end

-- 終了手順 1: 自前 worktree の未コミット変更を検知し、必要なら確認する。
-- キャンセルは close を最初から中止 (状態変更を一切走らせない)。
local function close_with_worktree(cb, after_remove)
  local current = active
  if current == nil then
    return
  end
  if not owned_worktree(current.session) then
    finish_close(current, false, false, cb, after_remove)
    return
  end
  git_worktree.status({
    repo = current.session.repo,
    path = current.session.worktree.path,
  }, function(res)
    if not res.ok then
      -- 検知不能 (dir 消失 etc) を clean と混同しない: 掃除は走らせず WARN。
      notify_warn(res.error)
      finish_close(current, false, true, cb, after_remove)
      return
    end
    if res.data.dirty then
      confirm(force_prompt(current.session.worktree.path), function(yes)
        if yes then
          finish_close(current, true, false, cb, after_remove)
        end
        -- キャンセル = close 中止 (セッション・UI・保存状態は何も変わらない)
      end)
      return
    end
    finish_close(current, false, false, cb, after_remove)
  end)
end

-- ============================================================================
-- panel 一覧と窓装飾 (chrome: w:review_winbar 一本化)
-- ============================================================================

-- panel 絞り込みの可視 files。render 側と移動系 (<Tab>/<S-Tab>/[F/]F) の進む順が
-- 必ず同じ集合を
-- 向くよう、可視一覧はこの 1 関数からのみ供給する (filter は view state で
-- session JSON に載せない — 復元・開き直し後は全一覧が正しい)。
local function visible_files()
  return ui_filepanel.visible(active.file_order_sorted, sidebar_filter)
end

-- «Showing changes for: <base>..<head 表示名>» の後者 (DESIGN 決定表: 通常経路は
-- 作業ツリー、scratch 縮退時は ref 名)。
local function panel_head_display()
  if active.degraded then
    return active.session.head
  end
  return '作業ツリー'
end

local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

local function comments_for(session, path)
  local n = 0
  for _, c in ipairs(session.comments or {}) do
    if c.file == path then
      n = n + 1
    end
  end
  return n
end

-- head 窓 winbar (diff-review「窓装飾 (chrome)」)。告知窓 (binary/deleted) は
-- +a -d / 件数を持たないので告知語に差し替える。
local function head_winbar_text(session, cur)
  local refs = ('%s..%s'):format(session.base or '', session.head or '')
  if cur.kind == 'no-changes' then
    return refs .. ' · 変更なし'
  end
  if cur.kind == 'binary' then
    return ('%s · %s · binary'):format(refs, cur.path)
  end
  if cur.kind == 'deleted' then
    return ('%s · %s · deleted'):format(refs, cur.path)
  end
  return ('%s · %s · +%d -%d · %s'):format(
    refs,
    cur.path,
    cur.file and cur.file.added or 0,
    cur.file and cur.file.deleted or 0,
    plural(comments_for(session, cur.path), 'comment')
  )
end

local function base_winbar_text(cur)
  if cur.kind == 'no-changes' then
    return '変更なし'
  end
  if cur.kind == 'binary' then
    return ('base · %s (binary)'):format(cur.path)
  end
  if cur.kind_base_null == true then
    return ('base · %s (new file)'):format(cur.path)
  end
  return ('base · %s (git show)'):format(cur.path)
end

-- 集約先 (head バッファ) の無い outdated の件数 — panel winbar 末尾 `⚠N`
-- (diff-review「窓装飾」/ persistence-restore「anchor 検証」)。告知窓ファイル
-- (deleted / binary) と、いまの差分に現れないコメントファイル。差分まるごと
-- 消滅開通は placeholder が全 outdated の集約先になるので 0。
local function hidden_outdated_count()
  if active == nil then
    return 0
  end
  if active.current ~= nil and active.current.kind == 'no-changes' then
    return 0
  end
  local n = 0
  for _, c in ipairs(active.session.comments or {}) do
    if c.state == 'outdated' then
      local f = active.files_by_path[c.file]
      if f == nil or f.status == 'D' or f.binary == true then
        n = n + 1
      end
    end
  end
  return n
end

-- 3 窓の chrome 再適用 (render 直後の handlers 側再適用 — diff-review「窓装飾」。
-- 窓 number は窓ローカル、winbar 文字列は w:review_winbar のみで持つ)。
local function apply_chrome()
  if active == nil then
    return
  end
  local pw = ui_windows.win 'panel'
  local bw = ui_windows.win 'base'
  local hw = ui_windows.win 'head'
  ui_chrome.window(pw)
  if pw ~= nil then
    -- 相互ハイライト: 選択行 hl (filepanel) + 窓 cursorline (diff-review「file panel」)
    vim.wo[pw].cursorline = true
  end
  ui_chrome.window(bw)
  ui_chrome.window(hw)
  if pw ~= nil and active.panel_buf ~= nil and vim.api.nvim_buf_is_valid(active.panel_buf) then
    ui_chrome.winbar(
      pw,
      ui_filepanel.winbar(active.session, visible_files(), {
        filter = sidebar_filter,
        hidden_outdated = hidden_outdated_count(),
      })
    )
  end
  if active.current ~= nil then
    if hw ~= nil then
      ui_chrome.winbar(hw, head_winbar_text(active.session, active.current))
    end
    if bw ~= nil then
      ui_chrome.winbar(bw, base_winbar_text(active.current))
    end
  end
end

local function refresh_panel(cursor_entry)
  if active == nil then
    return
  end
  active.panel_buf = ui_filepanel.render(active.session, visible_files(), {
    mode = panel_mode,
    collapsed = panel_collapsed,
    head_display = panel_head_display(),
    cursor = cursor_entry,
  })
  ui_keygate.install(active.panel_buf)
  active.owned_bufs[active.panel_buf] = true
  ui_windows.set_panel_buf(active.panel_buf)
  apply_chrome()
end

-- dir entry «開く» (<CR> / o) = 折り畳みトグル。dir 行自身は残り、子行 (連結 chain
-- 含む) を隠す。カーソル contract: 同じ dir entry を指したまま (filepanel.render が
-- entry で追従、隠れない) — diff-review「file panel」折込カーソル。
local function toggle_dir_collapse(path)
  if panel_collapsed[path] == true then
    panel_collapsed[path] = nil
  else
    panel_collapsed[path] = true
  end
  refresh_panel { kind = 'dir', path = path }
end

--- `i` (file panel): list 表示 (フルパス 1 行) ⇄ tree 表示の切替。view state で
--- save しない。filter / collapsed / 選択 entry は.mode の切り替えを跨ぐ (tree 側で
--- 畳んだ dir は list 表示では効かず、全ファイル行が出る)。
function M.toggle_listing_style()
  if active == nil then
    return
  end
  panel_mode = (panel_mode == 'tree') and 'list' or 'tree'
  refresh_panel()
end

--- `/`: panel 一覧を絞り込む。空入力 = 解除、キャンセル (Esc) = 現状維持。
--- 一致 0 件でも一覧は開いたまま (winbar に解除手順を出す)。
function M.filter_sidebar()
  if active == nil then
    return
  end
  vim.ui.input({ prompt = 'review filter: ' }, function(text)
    if text == nil then
      return
    end
    sidebar_filter = (text == '') and nil or text
    refresh_panel()
  end)
end

-- ============================================================================
-- 窓へ張るバッファの解決 (head / base 窓の中身分岐) と開き直し破棄
-- ============================================================================

-- head 実ファイル / 縮退 scratch の基準 dir: branch = repo、PR = 自前 worktree。
local function review_dir()
  local wt = worktree_of(active.session)
  if wt ~= nil and wt.created_by_us == true and dir_exists(wt.path) then
    return wt.path
  end
  return active.session.repo
end

local function track_scratch(bufnr)
  active.scratch_bufs[#active.scratch_bufs + 1] = bufnr
  active.owned_bufs[bufnr] = true
  ui_keygate.install(bufnr)
end

-- git show 充填の非同期コールバックが old open のものだった場合の破棄
-- (高速 <CR> 連打 / close 後着。fill_token で世代管理)。
local function fill_show(bufnr, ref, path, token)
  git_ref.show_text({ ref = ref, path = path, cwd = review_dir() }, function(res)
    if active == nil or active.fill_token ~= token then
      return -- 開き直し済み / close 済み: 結果を捨てて窓の状態を守る
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    ui_scratchwin.set_content(bufnr, res.ok and res.data or {})
  end)
end

-- base 窓 = git show <base>:<リゾルブ後 path> scratch。追加ファイル (A) は
-- 0 行の review://null、rename は旧パスの中身、旧パス自体が新規なら git 失敗
-- で null 相当 (空) になる (diff-review「head / base 窓の中身」)。
local function open_base_scratch(cur, file, token)
  local sid = active.session.id
  if file ~= nil and file.status == 'A' then
    cur.kind_base_null = true
    cur.base_buf = ui_scratchwin.buffer { kind = 'null', session_id = sid, path = cur.path }
    track_scratch(cur.base_buf)
    return
  end
  cur.base_buf = ui_scratchwin.buffer { kind = 'base', session_id = sid, path = cur.path }
  -- 窓の中身表 «filetype detect» (内容と同じ名前の path から判定)。null (追加) は
  -- 0 行なので detect しない。告知窓 (deleted/binary) も告知 1 行のまま。
  ui_scratchwin.detect_filetype(cur.base_buf, cur.path)
  track_scratch(cur.base_buf)
  local base_path = (file ~= nil and file.old_path) or cur.path
  fill_show(cur.base_buf, active.session.base, base_path, token)
end

-- head 実ファイル窓: 同名バッファがあれば再利用 (ユーザーが自分の窓で開いて
-- いても同一バッファ)、無ければ bufadd + bufload (:edit 相当。窓を作らずに
-- buffer だけ用意し、窓への掲示は windows.bind の set_buf に一本化する =
-- 「窓を作ってから set_buf」契約)。filetype / LSP は BufRead 系の標準経路。
local function open_head_real(full)
  local existing = vim.fn.bufnr(full)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    -- 再利用分岐でも張込と所有登録は必須 (窓の中身表 «既にユーザーが開いていれば
    -- 同一バッファを再利用» は「中身が同じ」だけで「head 窓のキーが効く」ではない —
    -- 張込を飛ばすと c/e/d/y/i/o/q が全滅)。張込は冪等 (自前マップは衝突と数えない /
    -- install_one は同 rhs 再設定)、所有登録で close / tab 消滅の uninstall が
    -- ユーザーバッファに残骸 0 契約として届くようになる。
    active.owned_bufs[existing] = true
    ui_keygate.install(existing)
    return existing
  end
  local buf = vim.fn.bufadd(full)
  pcall(vim.fn.bufload, buf)
  active.owned_bufs[buf] = true
  ui_keygate.install(buf)
  return buf
end

--- 移動系 (panel <CR>/o/l 以外の開く導線・<Tab>/<S-Tab>/[F/]F・開始/復元時の
--- 初期開き) が
--- 必ず通る単一经路 (diff-review「open_file(path)」)。種別解決 → 窓に base/head を
--- 張り、chrome 再適用、panel 再描画、コメント extmark 再適用 (マークは変えない)。
local function resolve_and_open(path)
  if active == nil then
    return
  end
  local session = active.session
  local cur = { path = path }
  active.fill_token = active.fill_token + 1
  local token = active.fill_token
  local file = active.files_by_path[path]
  cur.file = file

  if path == M.NO_CHANGES then
    cur.kind = 'no-changes'
    local buf = ui_scratchwin.buffer { kind = 'base', session_id = session.id, path = path }
    ui_scratchwin.set_content(buf, { '変更なし' })
    track_scratch(buf)
    cur.base_buf = buf
    cur.head_buf = buf
    ui_windows.bind(buf, buf, { diffoff = 'both' })
    active.current = cur
    -- 張り先が無い outdated (全ファイル消滅) は placeholder に集約する
    ui_commentmarks.clear_tracked()
    ui_commentmarks.apply(session, buf, M.NO_CHANGES)
    apply_chrome()
    return
  end

  -- 種別の解決 (head 側 → base 側の順。「head / base 窓の中身」表)
  if file ~= nil and file.binary == true then
    cur.kind = 'binary'
    local buf = ui_scratchwin.buffer { kind = 'binary', session_id = session.id, path = path }
    ui_scratchwin.set_content(buf, ui_scratchwin.NOTIFY.binary)
    track_scratch(buf)
    cur.base_buf = buf
    cur.head_buf = buf
    ui_windows.bind(buf, buf, { diffoff = 'both' })
  elseif file ~= nil and file.status == 'D' then
    -- 削除: head 窓に告知 scratch + diffoff (:edit 不可 — DESIGN「既知の制約」)。
    cur.kind = 'deleted'
    local hb = ui_scratchwin.buffer { kind = 'deleted', session_id = session.id, path = path }
    ui_scratchwin.set_content(hb, ui_scratchwin.NOTIFY.deleted)
    track_scratch(hb)
    cur.head_buf = hb
    open_base_scratch(cur, file, token)
    ui_windows.bind(cur.base_buf, hb, { diffoff = 'head' })
  else
    open_base_scratch(cur, file, token)
    if active.degraded then
      -- scratch 縮退: head も git show <head>:<path> の読み取り専用 scratch。
      cur.kind = 'degraded'
      local hb = ui_scratchwin.buffer { kind = 'head', session_id = session.id, path = path }
      ui_scratchwin.detect_filetype(hb, path)
      track_scratch(hb)
      cur.head_buf = hb
      fill_show(hb, session.head, path, token)
      ui_windows.bind(cur.base_buf, hb)
    else
      local full = vim.fs.joinpath(review_dir(), path)
      if vim.uv.fs_stat(full) == nil then
        -- head 解決後は通常実在するが、外部で消された場合のみ告知窓へ倒す
        -- (:edit すると :w で空ファイルが復活する経路を作らない — 削除と同型)。
        cur.kind = 'deleted'
        local hb = ui_scratchwin.buffer { kind = 'deleted', session_id = session.id, path = path }
        ui_scratchwin.set_content(hb, ui_scratchwin.NOTIFY.deleted)
        track_scratch(hb)
        cur.head_buf = hb
        ui_windows.bind(cur.base_buf, hb, { diffoff = 'head' })
      else
        cur.kind = 'real'
        cur.head_buf = open_head_real(full)
        ui_windows.bind(cur.base_buf, cur.head_buf, { head_kind = 'real' })
      end
    end
  end

  active.current = cur

  -- extmark 再適用: 常に session から捨てて再構成。「同一バッファの全窓に
  -- スレッドが見える」仕様なので掃除済み残骸の再適用のみここで行う
  -- (ui/commentmarks が張った全バッファを tracking し、close / 切替で clear)。
  ui_commentmarks.clear_tracked()
  if cur.kind == 'real' or cur.kind == 'degraded' or cur.kind == 'no-changes' then
    ui_commentmarks.apply(active.session, cur.head_buf, path)
  end

  -- panel カーソルを開いたファイル行へ逆追従 (<CR> 以外の移動系・初期開き含む)。
  -- open はレビュー完了マーク (files[path].viewed = 行頭 [✓]) を変えない:
  -- マークは panel の x でユーザーがトグルするのみ (diff-review「file panel」)。
  -- したがって open_file の共通経路は永続状態を変えず save も不要
  -- (INV-4 の save 対象 = コメント CRUD / マーク切替 / 差分再取得)。
  refresh_panel(path == M.NO_CHANGES and nil or { kind = 'file', path = path })
  apply_chrome()
end

--- panel 外導線 (open_selected_file / <Tab>/<S-Tab>/[F/]F / API) 共通の open_file。
--- active が無いか path が現差分に一覧化されていない場合は WARN/no-op。
function M.open_file(path)
  if active == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  if path == nil or (active.files_by_path[path] == nil and active.session.files[path] == nil) then
    return
  end
  resolve_and_open(path)
end

-- ============================================================================
-- review tab の消滅経路 (b): ユーザーが :tabclose / :tabonly 等で直接閉じる
-- ============================================================================

-- close と違い status=open を維持したまま save し、UI 側掃除 (extmark /
-- キー) だけ行う (diff-review「review tab の消滅経路」。契約化された close で
-- ある q / :Review close は finish_close 側)。worktree には触らない。
local function on_review_tab_closed()
  local current = active
  if current == nil then
    return
  end
  active = nil
  reset_panel_view_state()
  ui_commentmarks.clear_tracked()
  for buf in pairs(current.owned_bufs) do
    ui_keygate.uninstall(buf)
  end
  -- 開いていた窓は消えている (tab 全体)。scratch buffer は hide 状態で残るが、
  -- 開き直し時に同一名的のまま中身再充填るので残置 (セッション open のまま、が
  -- 定義)。extmark だけ実ファイル窓から確実に消す (上の clear_tracked)。
  local res = store.save(current.session)
  if not res.ok then
    notify_warn(res.error)
  end
  vim.notify(
    'review.nvim: レビュー tab を閉じました (セッションは保存済み・`:Review` で開き直し可)',
    vim.log.levels.INFO
  )
end

-- ============================================================================
-- head 解決フロー (branch のみ / docs/design/DESIGN.md 決定表「head が現在の
-- HEAD と違うとき」/ docs/design/features/diff-review.md「入出力と振る舞い」2)
-- ============================================================================

-- 縮退の確定文言 (diff-review「開始」2 «…» の通り)。
local DEGRADED_INFO =
  'head の状態はチェックアウトされていません。読み取り専用 scratch でレビューします'

local function degraded_notify()
  vim.notify('review.nvim: ' .. DEGRADED_INFO, vim.log.levels.INFO)
end

local function switch_offer(head)
  return (
    'review.nvim: head %s は現在のチェックアウトと別のコミットです。'
    .. 'git switch で %s に切り替えてレビューしますか? [y/N]: '
  ):format(head, head)
end

--- branch の head 解決。cb(degraded): true = scratch 縮退 (diff は 2 引数形)。
--- 一致 -> 通常経路 / 不一致 + ローカルブランチ + clean -> [y/N] switch 提案
--- (承諾 -> git switch、失敗は WARN + 縮退) / 拒否・dirty・非ローカルブランチ
--- -> 縮退 INFO。rev-parse <head> 失敗は提案も案内も出さず縮退形で diff に渡す
--- (E_REF の通知は diff 本体が行う)。switch は確認を通過したときだけ (INV-3)。
local function resolve_head(args, cb)
  git_ref.rev_parse({ ref = args.head, cwd = args.repo }, function(h)
    if not h.ok then
      cb(true)
      return
    end
    local function mismatch_path()
      git_ref.is_local_branch({ ref = args.head, cwd = args.repo }, function(lb)
        if not lb.ok then
          degraded_notify()
          cb(true)
          return
        end
        git_worktree.status({ repo = args.repo, path = args.repo }, function(st)
          -- 検知不能 (status 失敗) も dirty と同等に扱う (INV-3 の安全側)
          if not st.ok or st.data.dirty then
            degraded_notify()
            cb(true)
            return
          end
          confirm(switch_offer(args.head), function(yes)
            if not yes then
              degraded_notify()
              cb(true)
              return
            end
            git_repo.switch({ ref = args.head, cwd = args.repo }, function(sw)
              if sw.ok then
                cb(false)
                return
              end
              notify_warn(
                ('git switch に失敗しました。読み取り専用 scratch でレビューします: %s'):format(
                  sw.error
                )
              )
              degraded_notify()
              cb(true)
            end)
          end)
        end)
      end)
    end
    git_ref.rev_parse({ ref = 'HEAD', cwd = args.repo }, function(cur)
      if cur.ok and cur.data == h.data then
        cb(false)
        return
      end
      mismatch_path()
    end)
  end)
end

-- ============================================================================
-- 差分取得の下準備 (開始 / 復元 共通)
-- ============================================================================

--- args = { repo, id, mode, base, head, record? } -> cb(result)。
--- 成功 result.data = { files, worktree, degraded }。
--- branch: head 解決 -> 解に一致した引数形で diff (通常 = 単引数 `git diff
--- <base>` の作業ツリー基準 / 縮退 = `<base> <head>`) -> worktree 判断 (branch は
--- 作らないので created_by_us 名残の掃除のみ)。pr: worktree を作ってから
--- cwd=worktree の単引数 diff (pr-worktree「PR 解決」3)。
--- 失敗は結果型で返す (E_REF / E_WORKTREE / E_CANCELLED)。通知は呼び出し側
--- (開始と復元で E_REF 翻訳後の扱いが同じなので rules は fetch_and_begin 側で統一)。
function M.fetch_prepared(args, cb)
  if args.mode == 'pr' then
    M.resolve_worktree({
      repo = args.repo,
      id = args.id,
      mode = 'pr',
      head = args.head,
      record = args.record,
    }, function(wres)
      if not wres.ok then
        cb(wres)
        return
      end
      git_diff.fetch({ base = args.base, cwd = wres.data.path }, function(res)
        if not res.ok then
          cb(res)
          return
        end
        cb(result.ok { files = res.data.files, worktree = wres.data, degraded = false })
      end)
    end)
    return
  end
  resolve_head(args, function(degraded)
    git_diff.fetch({
      base = args.base,
      head = degraded and args.head or nil,
      cwd = args.repo,
    }, function(res)
      if not res.ok then
        cb(res)
        return
      end
      M.resolve_worktree({
        repo = args.repo,
        id = args.id,
        mode = 'branch',
        head = args.head,
        record = args.record,
      }, function(wres)
        if not wres.ok then
          cb(wres)
          return
        end
        cb(result.ok { files = res.data.files, worktree = wres.data, degraded = degraded })
      end)
    end)
  end)
end

local function fetch_and_begin(args, existing)
  M.fetch_prepared({
    repo = args.repo,
    id = args.id,
    mode = args.mode,
    base = args.base,
    head = args.head,
    record = existing ~= nil and worktree_of(existing) or nil,
  }, function(res)
    if not res.ok then
      -- E_CANCELLED はユーザー自身の中断なので通知しない (close の確認と同じ)。
      if res.code == result.codes.E_CANCELLED then
        return
      end
      if res.code == result.codes.E_REF then
        notify_warn(usermsg.git_ref_error(res.error))
        return
      end
      notify_warn(res.error)
      return
    end
    if #res.data.files == 0 then
      vim.notify(
        ('review.nvim: 変更なし (%s..%s): レビュー対象がありません'):format(
          args.base,
          args.head
        ),
        vim.log.levels.INFO
      )
      -- 開始は開かない = save しない。pr は作成が diff に先行するので、作りたての
      -- 自前 worktree をそのまま孤児にしない (記録が無いと起動 scan も拾えない)。
      local wt = res.data.worktree
      if type(wt) == 'table' and wt.created_by_us == true then
        -- remove / prune も worktree 登録変更なので resolve_worktree と同じ
        -- wt_with_lock(path) 下で走らせる (finish_close と同形、全終了経路で
        -- 解除)。remove 最中の concurrent add は二重登録 (main--x + main--x1) の
        -- 源で、この掃除が lock 外だと窓を reopen する (pr-worktree.md
        -- 「worktree 登録操作の直列化」)。
        wt_with_lock(wt.path, function()
          git_worktree.remove({ repo = args.repo, path = wt.path }, function(rres)
            if not rres.ok then
              notify_warn(
                ('0 差分セッションの worktree 掃除に失敗しました: %s'):format(
                  rres.error
                )
              )
              prune_and_rm_dir(args.repo, wt.path, function()
                wt_unlock(wt.path)
              end)
              return
            end
            wt_unlock(wt.path)
            -- 既存保存セッションの記録を再利用 (または旧記録と同じ path を
            -- 再作成) していた場合、worktree を消した後に JSON が実在しない
            -- dir を指したまま残らないよう記録を nil 化して save する
            -- (comments / refs / status はそのまま。開始で開かない = 新規 save はしない)。
            -- 掃除が完遂できなかった側は created_by_us 記録を残し、起動 scan が
            -- 回収できる状態を保つ (delete の「dir を消せなければ JSON を残す」と同方針)。
            local existing_wt = existing ~= nil and worktree_of(existing) or nil
            if existing_wt ~= nil and existing_wt.path == wt.path then
              existing.worktree = vim.NIL
              local sres = store.save(existing)
              if not sres.ok then
                notify_warn(sres.error)
              end
            end
          end)
        end)
      end
      return
    end
    begin_session(args, res.data.files, existing, res.data.worktree, res.data.degraded)
  end)
end

-- 衝突 / 切替 / 継承の確認を消化して fetch へ進む。args = { repo, id, mode,
-- base, head, pr?, info? } (:Review start と :Review pr で共通 — handlers/pr)。
local function proceed(args)
  local slug = args.id
  if active ~= nil and active.session.id == slug then
    vim.notify(
      ('review.nvim: %s のレビューは既に開いています'):format(slug),
      vim.log.levels.INFO
    )
    return
  end
  local existing = store.load(args.repo, slug).data
  if existing ~= nil and paths.slug_conflict(existing, args.base, args.head) then
    notify_warn(
      ('slug %s に既存セッション (%s..%s) があります。:Review delete %s で削除してください'):format(
        slug,
        existing.base,
        existing.head,
        slug
      )
    )
    return
  end

  local function go(inherit)
    fetch_and_begin(args, inherit and existing or nil)
  end

  -- 同一 refs 組の保存済み (existing) がある開始は active の有無に関わらず
  -- 継承のみで、既存を消す上書き開始はできない (diff-review.md「開始と既存
  -- セッションの継承」/ persistence-restore.md「1 組 1 セッション」)。active の
  -- close 確認と継承確認は 1 回に統合する (二重確認にしない)。
  if existing ~= nil then
    if active ~= nil then
      confirm(
        (
          'review.nvim: active セッション %s です。閉じて %s を継承しますか？'
          .. ' コメント・完了マーク内容も引き継ぎます [y/N]: '
        ):format(active.session.id, slug),
        function(yes)
          if yes then
            -- close の掃除 (status 確認含む) の完了を待ってから新セッションへ (INV-1)。
            close_with_worktree(function()
              go(true)
            end)
          end
        end
      )
      return
    end
    confirm(
      (
        'review.nvim: 既存セッション %s (%s..%s, コメント %d 件) に同じ refs 組の開始です。'
        .. 'コメント内容を継承して開きますか？ [y/N]: '
      ):format(slug, existing.base, existing.head, #(existing.comments or {})),
      function(yes)
        if yes then
          go(true)
        end
      end
    )
    return
  end
  if active ~= nil then
    confirm(
      ('review.nvim: active セッション %s です。閉じて %s を開始しますか？ [y/N]: '):format(
        active.session.id,
        slug
      ),
      function(yes)
        if yes then
          close_with_worktree(function()
            go(false)
          end)
        end
      end
    )
    return
  end
  go(false)
end

local function with_repo_top(cb)
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(res)
    if not res.ok then
      notify_warn(res.error)
      return
    end
    cb(res.data)
  end)
end

--- 開始フロー共通の入口 (handlers/pr が mode=pr の args を組んで呼ぶ。
--- handlers/session 側で gh / ref 解決を行わないための境界)。
function M.begin(args)
  proceed(args)
end

--- `:Review start <base> [head]` の開始。戻り値はディスパッチ受理
--- (git 成否は非同期 notify / UI、base 欠損だけ同期 err)。
--- head 省略 = `rev-parse --abbrev-ref HEAD` を自動採用・保存し、入力 UI を
--- 出さない (DESIGN.md 決定表「head 省略」/ diff-review.md「開始」1)。
function M.start(opts)
  if type(opts) ~= 'table' or opts.base == nil or opts.base == '' then
    return result.err(
      'review.nvim: :Review start <base> [head] の形式で指定してください',
      nil
    )
  end
  with_repo_top(function(repo)
    local function start_with(head)
      proceed {
        repo = repo,
        id = paths.branch_slug(opts.base, head),
        mode = 'branch',
        base = opts.base,
        head = head,
      }
    end
    if opts.head ~= nil and opts.head ~= '' then
      start_with(opts.head)
      return
    end
    git_ref.abbrev_ref_head({ cwd = repo }, function(res)
      if not res.ok then
        notify_warn(res.error)
        return
      end
      -- detached HEAD は literal "HEAD" がそのまま返る (保存後も同じ解決経路で復元可)
      start_with(res.data)
    end)
  end)
  return result.ok()
end

--- `:Review close` / q。コメント 0 件なら無確認で閉じる。
--- worktree がある場合は状態検知 -> (必要なら) 確認 -> save/clean-up の順 (pr-worktree.md)。
function M.close()
  if active == nil then
    return result.err(
      'review.nvim: アクティブなセッションがありません',
      result.codes.E_NOT_ACTIVE
    )
  end
  local count = #active.session.comments
  if count > 0 then
    confirm(
      ('review.nvim: コメント %d 件のセッション %s を閉じますか？ [y/N]: '):format(
        count,
        active.session.id
      ),
      function(yes)
        if yes then
          close_with_worktree(nil)
        end
      end
    )
  else
    close_with_worktree(nil)
  end
  return result.ok()
end

--- head/base/panel 窓の q キー。:Review close と同一 (tab を閉じる。ユーザー窓・
--- 開いたままの実ファイルバッファ (modified を含む) は消さない)。
function M.close_by_key()
  local res = M.close()
  if not res.ok then
    vim.notify(res.error, vim.log.levels.WARN)
  end
end

--- 確認なし (フロー側の事前確認済み) で閉じる。復元 / 一覧からの再開で呼ぶ。
--- worktree の status 確認と --force 確認は close と同じ (ユーザーデータ保護は省略不可)。
function M.force_close(cb)
  close_with_worktree(cb)
end

--- `:Review delete <id>`。確認 -> close 相当の掃除 -> JSON 削除 -> 自前 ref 削除
--- (pr-worktree.md「セッションの削除」。closed でも created_by_us 残骸があれば
--- 掃除してから消し、孤児 dir を残さない。active 同一 id では非同期の worktree
--- remove 完了を待ってから JSON+ref を消す。掃除が完遂できない場合は JSON を
--- 残して中止 = closed 記録として起動 scan が回収できる)。
function M.delete(id)
  if id == nil or id == '' then
    notify_warn ':Review delete <id> の形式で指定してください'
    return result.err('missing id', result.codes.E_REF)
  end
  with_repo_top(function(repo)
    local sess = store.load(repo, id).data
    if sess == nil then
      notify_warn(('セッション %s が見つかりません'):format(id))
      return
    end
    confirm(
      ('review.nvim: セッション %s (コメント %d 件) を削除しますか？ コメントも失われます [y/N]: '):format(
        id,
        #(sess.comments or {})
      ),
      function(yes)
        if not yes then
          return
        end
        local function finalize()
          local res = store.delete(repo, id)
          if not res.ok then
            notify_warn(res.error)
            return
          end
          -- このセッション用に作った自前 ref (review-nvim/pr-<n>) も消す
          -- (close では残し、delete だけで消す — DESIGN.md「既知の制約」ref 方針)。
          local pr = sess.pr
          if sess.mode == 'pr' and type(pr) == 'table' and pr.number ~= nil then
            git_ref.delete_ref(
              { ref = git_ref.pr_ref_storage(pr.number), cwd = repo },
              function() end
            )
          end
        end
        if active ~= nil and active.session.id == id then
          -- active と同じ id: close の 1〜3 を先に実行し、**非同期の worktree
          -- remove (手順 3) の完了を待って**から JSON+ref を消す
          -- (pr-worktree.md「セッションの削除」。remove 完了前に JSON を消すと
          -- 失敗時に孤児 dir を scan が回収できない — closed 残骸側 (else 以下)
          -- と同じ「孤児 dir を残さない」不変条件: dir が残るなら prune+remove_dir
          -- で回収してから削除、それも失敗なら JSON を残して中止 = scan 回収可)。
          local closing_wt = worktree_of(active.session)
          close_with_worktree(nil, function()
            if
              closing_wt == nil
              or closing_wt.created_by_us ~= true
              or not dir_exists(closing_wt.path)
            then
              finalize()
              return
            end
            sweep_or_abort(repo, closing_wt.path, finalize)
          end)
          return
        end
        local wt = worktree_of(sess)
        if wt == nil or wt.created_by_us ~= true or not dir_exists(wt.path) then
          finalize()
          return
        end
        -- closed の作成分残骸 (close の掃除失敗経路): status -> remove ->
        -- 失敗時 prune + dir 再帰削除。全部失敗したら孤児 dir を残さないため中止。
        git_worktree.status({ repo = repo, path = wt.path }, function(sres)
          local dirty = sres.ok and sres.data.dirty
          local function with_remove(force)
            wt_with_lock(wt.path, function()
              git_worktree.remove({ repo = repo, path = wt.path, force = force }, function(rres)
                if rres.ok then
                  wt_unlock(wt.path)
                  finalize()
                  return
                end
                sweep_or_abort(repo, wt.path, function()
                  wt_unlock(wt.path)
                  finalize()
                end)
              end)
            end)
          end
          if dirty then
            confirm(force_prompt(wt.path), function(approved)
              if approved then
                with_remove(true)
              end
              -- キャンセル = 削除中止 (close のキャンセルと同じ意味)
            end)
            return
          end
          with_remove(false)
        end)
      end
    )
  end)
  return result.ok()
end

-- ============================================================================
-- セッション組み立てと UI 開通
-- ============================================================================

-- 直近 parse (new 側) 差分 files からファイル状態を組み替える: files_by_path /
-- file_order / session.files / sidebar 昇順一覧。anchor 検証と「差分がまるごと
-- 消滅 -> 全コメント outdated」は text_map 経路ここだけ (persistence-restore
-- 「anchor 検証」= 開始 / 復元 / リフレッシュで同一。規則を 3 経路に重複させない)。
-- session.files を更新し、(files_by_path, file_order, sorted) を返す。
local function build_file_state(session, files)
  local files_by_path = {}
  local file_order = {}
  for _, file in ipairs(files) do
    files_by_path[file.path] = file
    file_order[#file_order + 1] = file.path
  end
  anchor.verify(session.comments, files_by_path)
  if #files == 0 then
    -- 「差分がまるごと消滅」: 再取得差分が 0 ファイルなら anchor 照合の余地が
    -- 無いので全コメントを outdated 化する (persistence-restore.md。anchor 欠損
    -- で検証スキップの active を残さない)。
    for _, comment in ipairs(session.comments) do
      comment.state = 'outdated'
    end
  end

  -- files = 差分に出る全ファイル (DESIGN.md「データスキーマ」)。再取得で消えた
  -- コメント付きファイルは map にも一覧にも合成行を作らない: window diff の
  -- 張り先が無いファイルの outdated は panel winbar 末尾 ⚠N とプロンプト除外
  -- INFO で可視化する (persistence-restore「anchor 検証」「差分がまるごと消滅」。
  -- 合成 scratch kind を review:// 契約 (base/head/null/deleted/binary) に足さない)。
  local old_files = session.files or {}
  local new_files = {}
  for _, path in ipairs(file_order) do
    local old = old_files[path]
    new_files[path] = { viewed = old ~= nil and old.viewed or false }
  end
  session.files = new_files

  local sorted = {}
  for _, file in ipairs(files) do
    sorted[#sorted + 1] = file
  end
  -- 一覧の先頭 = 初期開きファイルなので、pairs 順のまま繋ぐと復元経路だけ順序が揺れる。
  table.sort(sorted, function(a, b)
    return a.path < b.path
  end)
  return files_by_path, file_order, sorted
end

-- begin_session: diff パース結果からセッションを組み立て UI を開く。
-- args = { repo, id, mode, base, head, pr, info? } (pr-worktree.md「PR 解決」3 の
-- 開始時に handler が組み立てる)。worktree は解決済み値 (記録 | vim.NIL)、
-- degraded は head 解決フローの解 (scratch 縮退時 true。リフレッシュの再取得
-- 引数形を開始時解決と一致させるため active に保持する。session JSON には
-- 載せない — 復元時に head 解決フローを毎回再評価する)。
begin_session = function(args, files, existing, worktree, degraded)
  local session = existing
  if session == nil then
    session = {
      id = args.id,
      repo = args.repo,
      mode = args.mode,
      base = args.base,
      head = args.head,
      pr = args.pr or vim.NIL,
      worktree = vim.NIL,
      status = 'open',
      files = {},
      comments = {},
      created_at = now(),
    }
  end
  session.status = 'open'
  -- 作成判断の解を毎回上書き (crash 後の記録陳腐化を許さない — pr-worktree.md 異常終了回復)。
  session.worktree = worktree

  local files_by_path, file_order, sorted = build_file_state(session, files)

  -- 開き直し = 全一覧が正しい (前回の絞り込み・fold・list/tree を持ち込まない)
  reset_panel_view_state()
  reset_refresh_state()
  active = {
    session = session,
    files_by_path = files_by_path,
    file_order = file_order,
    file_order_sorted = sorted,
    panel_buf = nil,
    current = nil,
    degraded = degraded == true,
    -- リフレッシュ時 head commit 比較の INFO を 1 回に抑えるラッチ (セッション別)
    head_info_shown = false,
    fill_token = 0,
    owned_bufs = {},
    scratch_bufs = {},
  }
  persist()
  open_session_ui()
  if args.info ~= nil then
    -- PR タイトルは開始時 INFO のみ (セッションに永続化しない — pr-worktree.md)。
    vim.notify('review.nvim: ' .. args.info, vim.log.levels.INFO)
  end
end

open_session_ui = function()
  active.panel_buf = ui_filepanel.render(active.session, active.file_order_sorted, {
    mode = panel_mode,
    collapsed = panel_collapsed,
    head_display = panel_head_display(),
  })
  ui_keygate.install(active.panel_buf)
  active.owned_bufs[active.panel_buf] = true
  -- vsplit 継承 drift 回避と tcd は windows.open 内 (レビュー 3 窓を作ってから
  -- 内容を張る順序契約)。focus は head 窓で開始する。
  ui_windows.open { dir = review_dir(), on_tab_closed = on_review_tab_closed }
  ui_windows.set_panel_buf(active.panel_buf)
  local first = active.file_order_sorted[1]
  -- 「一覧先頭ファイルの open_file」(セッション開始時の初期開き)。files が
  -- 空 (復元で差分消滅) は NO_CHANGES プレースホルダを開く。
  resolve_and_open((first and first.path) or M.NO_CHANGES)
  ui_windows.sweep()
end

--- 読み込み済みセッションを new 側差分とともに開始処理へ引き継ぐ (restore ルート:
--- anchor 検証 -> files map 再構築 -> UI -> open save)。worktree の解決は
--- fetch_prepared 側で済んでいるため、解 (記録 | vim.NIL) を受ける。
--- 復元時の head 解決 (switch 提案 / scratch 縮退) も fetch_prepared が走る
--- (DESIGN.md 決定表「起動時復元」)。
function M.resume_into(session, files, worktree, degraded)
  begin_session({
    repo = session.repo,
    id = session.id,
    mode = session.mode,
    base = session.base,
    head = session.head,
    pr = session.pr,
  }, files, session, worktree, degraded)
end

-- ============================================================================
-- panel 操作と移動系 (c/e/d/y/i/o/q/R の導線は ui/keygate 経由)
-- ============================================================================

--- panel <CR>: 一覧のそのファイルを open_file (移動系と同一処理)。focus は
--- windows.bind が head 窓へ送る (sidebar に残ったままだと以降の c/e が
--- 一覧側に効かず無反応に見える — UX review F12)。
function M.open_selected_file()
  if active == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'sidebar' then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local entry = ui_filepanel.row_entry(buf, row)
  if entry == nil then
    return -- ヘッダ行 / 範囲外 (<CR> 無動作)
  end
  if entry.kind == 'dir' then
    -- dir entry «開く» = fold トグル (DESIGN キー表 <CR>/o/l。カーソルは dir 行に残る)
    toggle_dir_collapse(entry.path)
    return
  end
  M.open_file(entry.path)
end

--- コメント CRUD 直後の再永続化 + 表示更新 (INV-4、diff-review「コメント表示」
--- 再構成契約)。head 窓 extmark と winbar 件数、panel winbar を更新する。
--- 開いている head 窓が無い / 告知窓なら save と panel winbar のみ。
function M.commit_comment_change()
  if active == nil then
    return
  end
  persist()
  if active.current ~= nil then
    ui_commentmarks.clear_tracked()
    if active.current.kind == 'real' or active.current.kind == 'degraded' then
      ui_commentmarks.apply(active.session, active.current.head_buf, active.current.path)
    end
  end
  apply_chrome()
end

local function current_path()
  return active ~= nil and active.current ~= nil and active.current.path or nil
end

-- 移動系 (<Tab>/<S-Tab>/[F/]F): file panel の表示順 (ツリーを上から下) から次の
-- 対象を解決し open_file (処理は panel <CR> と同一)。render と同じ treelist.build
-- を単一源にし、折りたたみ dir の子・絞り込み外は表示と同一規則で飛ばす。
-- 現在位置が順序に無い (折りたたみ・絞り込みで隠れた) ときは次 = 先頭、前 = 無動作。
local function visible_order()
  local order = {}
  if active == nil then
    return order
  end
  local entries = {}
  for _, e in ipairs(visible_files()) do
    entries[#entries + 1] = {
      path = e.path,
      status = e.status,
      added = e.added,
      deleted = e.deleted,
      viewed = false,
    }
  end
  local rows = ui_treelist.build(entries, {
    mode = panel_mode,
    collapsed = panel_collapsed,
    base = active.session.base,
    head_display = panel_head_display(),
  })
  for _, row in ipairs(rows) do
    if row.kind == 'file' then
      order[#order + 1] = row.path
    end
  end
  return order
end

local function step_file(delta)
  local order = visible_order()
  if #order == 0 then
    return
  end
  local cur = current_path()
  local idx = 0
  for i, p in ipairs(order) do
    if p == cur then
      idx = i
      break
    end
  end
  local ni = idx + delta
  if ni < 1 or ni > #order then
    return
  end
  M.open_file(order[ni])
end

--- `<Tab>`: 次のファイルへ。
function M.next_file()
  step_file(1)
end

--- `<S-Tab>`: 前のファイルへ。
function M.prev_file()
  step_file(-1)
end

--- `[F`: 最初のファイルへ (現対象が最初なら無動作)。
function M.first_file()
  local order = visible_order()
  local target = order[1]
  if target == nil or target == current_path() then
    return
  end
  M.open_file(target)
end

--- `]F`: 最後のファイルへ (現対象が最後なら無動作)。
function M.last_file()
  local order = visible_order()
  local target = order[#order]
  if target == nil or target == current_path() then
    return
  end
  M.open_file(target)
end

--- `<leader>e`: panel へ focus を移す。窓が閉じられていた場合は左に再建し
--- render し直す (sidebar buf は bufhidden=wipe で表示窓と共に消える — AGENTS)。
function M.focus_sidebar()
  if active == nil then
    return
  end
  if active.panel_buf == nil or not vim.api.nvim_buf_is_valid(active.panel_buf) then
    active.panel_buf = nil
    local buf = ui_filepanel.render(active.session, visible_files(), {
      mode = panel_mode,
      collapsed = panel_collapsed,
      head_display = panel_head_display(),
    })
    ui_keygate.install(buf)
    active.owned_bufs[buf] = true
    active.panel_buf = buf
    active.scratch_bufs[#active.scratch_bufs + 1] = buf
  end
  ui_windows.show_panel(active.panel_buf)
  apply_chrome()
end

--- `<leader>b`: panel 表示トグル (panel を閉じても tab とレビュー窓は残る)。
--- 開いていれば窓を閉じる、無ければ再建して focus (diff-review「操作」表)。
function M.toggle_panel()
  if active == nil then
    return
  end
  if ui_windows.win 'panel' ~= nil then
    ui_windows.hide_panel()
    return
  end
  M.focus_sidebar()
end

--- 実ファイル参照 `o` (`o` の現窓解決: panel 行 or head/base 窓 = current_path)。
--- 前行儀 tab で repo/worktree 基準の実ファイルを開く (ui/fileview)。削除ファイルは
--- WARN (pr-worktree「実ファイル参照」)。scratch 縮退時は現在のチェックアウトの
--- 実ファイルである旨を INFO。checkout 側に無いファイルは fileview が git show
--- read-only へ倒す。
function M.open_file_current()
  if active == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local meta = vim.b[buf].review_meta or {}
  local path = current_path()
  if meta.kind == 'sidebar' then
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local entry = ui_filepanel.row_entry(buf, row)
    if entry == nil then
      return
    end
    if entry.kind == 'dir' then
      toggle_dir_collapse(entry.path)
      return
    end
    path = entry.path
  end
  if path == nil then
    notify_warn '対象ファイルが解決できません'
    return
  end
  local file = active.files_by_path[path]
  if file ~= nil and file.status == 'D' then
    notify_warn(('削除ファイル %s は開けません'):format(path))
    return
  end
  if active.degraded then
    vim.notify(
      ('review.nvim: %s は現在のチェックアウトの実ファイルです (head の状態は縮退中)'):format(
        path
      ),
      vim.log.levels.INFO
    )
  end
  local wt = worktree_of(active.session)
  ui_fileview.open({
    repo = active.session.repo,
    head = active.session.head,
    id = active.session.id,
    path = path,
    worktree = wt ~= nil and wt.path or nil,
    winbar = ('%s..%s · %s · read-only (git show)'):format(
      active.session.base or '',
      active.session.head or '',
      path
    ),
  }, function(err)
    if err ~= nil then
      notify_warn(err.error)
    end
  end)
end

--- panel x: viewed 切替 -> 直後に save (INV-4)。
function M.toggle_viewed_current()
  if active == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'sidebar' then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local target = ui_filepanel.row_entry(buf, row)
  if target == nil or target.kind ~= 'file' then
    return -- dir / ヘッダ行の x は無動作 (viewed はファイルの状態)
  end
  local path = target.path
  local entry = active.session.files[path] or { viewed = false }
  entry.viewed = not entry.viewed
  active.session.files[path] = entry
  persist()
  refresh_panel()
end

-- ============================================================================
-- handlers/comments への行解決の提供 (行写像 = head バッファ恒等)
-- ============================================================================

--- コメント操作 (c/e/d/y/i) が効く対象を解決する。ui/keygate が発火を gate 済み
--- だが、直接呼び出し (API・cmdline) でも同じ契約を守るためここで再度 window
--- role + 告知 scratch を弾く。head 実窓 / 縮退 head scratch の行番号が new 側
--- 行そのもの (INV-2) なので行変換はしない。
--- 返り値: target = { session,buf,path,commentable=true } か、
---        コメント不可理由つき { session, reason } か、session 不在 nil。
function M.comment_target()
  if active == nil then
    return nil
  end
  local cur = active.current
  if cur == nil then
    return { session = active.session, reason = 'window' }
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  -- 押下時点 gate: head 窓枠 + window gate 成立 + 表示バッファが current の
  -- head_buf と同一 (フィンガープリント)。base / panel / 告知窓はコメント不可。
  local role = ui_windows.role_of(win)
  if
    role ~= 'head'
    or vim.w[win].review_key_gate ~= win
    or buf ~= cur.head_buf
    -- placeholder / 告知 scratch は行参照先ファイルが存在しないのでコメント不可
    -- (旧契約「行写像が空 = 行参照操作は拒否」の置き換え)。
    or (cur.kind ~= 'real' and cur.kind ~= 'degraded')
  then
    return { session = active.session, reason = 'window' }
  end
  return { session = active.session, path = cur.path, buf = cur.head_buf, commentable = true }
end

--- 選択/カーソル行 range を new 側行 range (恒等) に解決する。head 実ファイル窓・
--- 縮退 scratch の現在の行番号がそのまま new 側。0 行数窓/告知では nil (呼び出し側
--- が «この窓にはコメントを付けられません» で弾く — c は存在行範囲のみ作成可)。
function M.ident_range(r1, r2)
  local target = M.comment_target()
  if target == nil or not target.commentable then
    return nil
  end
  local line_count = vim.api.nvim_buf_line_count(target.buf)
  if line_count == 0 then
    return nil
  end
  local lo = math.max(1, math.min(r1, r2, line_count))
  local hi = math.max(1, math.min(math.max(r1, r2), line_count))
  if r1 > line_count or r2 > line_count or r1 < 1 or r2 < 1 then
    return nil
  end
  return lo, hi, target
end

--- anchor: head バッファ (恒等行) の before/line/after テキスト。範囲外は vim.NIL。
function M.anchor_lines(buf, line)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local function text(l)
    if l < 1 or l > line_count then
      return vim.NIL
    end
    return vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
  end
  return { before = text(line - 1), line = text(line), after = text(line + 1) }
end

-- ============================================================================
-- リフレッシュ (未コミット反映契約, docs/design/features/diff-review.md
-- 「リフレッシュ」/ DESIGN 決定表「保存時再取得」)
-- ============================================================================

-- 窓 diff は `:w` 単体で再計算されない (DESIGN「既知の制約」huge-file-window-diff-
-- perf 実測) ため、再取得適用後に &diff の実ファイル窓へ :diffupdate を明示発火
-- する。窓 scan と呼ぶ側が契約で、実発火は注入可能 (spec は窓 diff の再計算自体で
-- なく「対象窓への発火」を pin する)。
local function default_diffupdate(win)
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, 'diffupdate')
  end)
end

local diffupdate = default_diffupdate

function M._set_diffupdate(fn)
  diffupdate = fn or default_diffupdate
end

--- バッファがセッションレビュー対象ファイルの実体 (repo / worktree 配下の
-- レビュー対象 path) なら repo 相対パス、そうでなければ nil を返す。
-- review:// scratch (base / 縮退 head / 告知窓)・セッション外・対象外ファイルは
-- 全部 nil。realpath を両側にかます (macOS /var のシンボリックリンク等の系差)。
-- 存在しないパスは素の正規化文字列に倒す。
local function session_file_of(current, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' or name:match '^review://' ~= nil then
    return nil
  end
  local full = vim.fn.fnamemodify(name, ':p')
  local real = vim.uv.fs_realpath(full)
  if real ~= nil then
    full = real
  end
  local roots = { current.session.repo }
  local wt = worktree_of(current.session)
  if wt ~= nil then
    roots[#roots + 1] = wt.path
  end
  for _, root in ipairs(roots) do
    local r = vim.uv.fs_realpath(root) or vim.fn.fnamemodify(root, ':p')
    r = (r:gsub('/+$', ''))
    if full:sub(1, #r + 1) == r .. '/' then
      local rel = full:sub(#r + 2)
      if current.files_by_path[rel] ~= nil then
        return rel
      end
    end
  end
  return nil
end

-- 再取得結果を active に適用する (diff-review「リフレッシュ」の順序: 再パース ->
-- anchor 検証 -> ±カウント・panel・スレッド・winbar 再適用 -> :diffupdate -> 永続化)。
-- 3 窓は head/base が張りっぱなしの実窓なので窓そのものは組み替えず、ファイル
-- 状態と表示だけを捨てて再構成する (commit_comment_change と同じ契約)。
local function apply_refresh(current, files)
  local session = current.session
  local files_by_path, file_order, sorted = build_file_state(session, files)
  current.files_by_path = files_by_path
  current.file_order = file_order
  current.file_order_sorted = sorted
  local cur = current.current
  if cur ~= nil and (cur.kind == 'real' or cur.kind == 'degraded') then
    -- 開き中のファイルの ±カウントを new 側 parse に差し替える (winbar / extmark
    -- 再適用の源)。再取得で消えたファイルは表示継続: head はユーザーの編集対象の
    -- 実ファイルなので窓を張り替えず、当該ファイルをゼロ差分 (+0 -0) として扱う
    -- (一覧と files map からは合成行を作らず除去 — 消失ファイルの outdated は
    -- panel winbar 末尾 ⚠N で可視化)。
    cur.file = files_by_path[cur.path]
      or {
        path = cur.path,
        status = 'M',
        binary = false,
        added = 0,
        deleted = 0,
      }
  end
  -- extmark 再適用: 常に session から捨てて再構成 (resolve_and_open と同一契約)。
  -- 告知窓 (deleted / binary) は張替先を持たないので掃除のみ。
  ui_commentmarks.clear_tracked()
  if cur ~= nil and (cur.kind == 'real' or cur.kind == 'degraded' or cur.kind == 'no-changes') then
    ui_commentmarks.apply(session, cur.head_buf, cur.path)
  end
  refresh_panel()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_get_option_value('diff', { win = win })
      and session_file_of(current, vim.api.nvim_win_get_buf(win)) ~= nil
    then
      diffupdate(win)
    end
  end
  persist()
end

-- session.head と 現在の HEAD の commit 違いを 1 回だけ INFO する (diff-review
-- 「リフレッシュ」4。処理は続行 — 定義上レビュー対象は base vs 現在のチェックアウト)。
-- branch の通常経路のみ: PR は worktree を --detach するため比較が恒真で誤発火、
-- scratch 縮退は再取得が作業ツリーを見ないので意味がない。告知済み (head_info_shown)
-- は以後の比較を打ち切る — 同じ告知を保存ごとに繰り返さない (INFO は「1 回だけ」)。
local HEAD_SWITCH_INFO =
  'セッション開始時の head と現在のチェックアウトが違います'

local function notify_head_switch_once(current)
  if current.head_info_shown or current.degraded or current.session.mode ~= 'branch' then
    return
  end
  git_ref.rev_parse({ ref = current.session.head, cwd = current.session.repo }, function(h)
    -- 比較中 close/切替 = 破棄。解決できない ref を不一致とは断定しない。
    if active ~= current or not h.ok then
      return
    end
    git_ref.rev_parse({ ref = 'HEAD', cwd = current.session.repo }, function(cur)
      if active ~= current or not cur.ok then
        return
      end
      if cur.data ~= h.data then
        current.head_info_shown = true
        vim.notify('review.nvim: ' .. HEAD_SWITCH_INFO, vim.log.levels.INFO)
      end
    end)
  end)
end

--- `R` / BufWritePost 共通のリフレッシュ調停 (`R` キーは ui/keygate と panel から
--- 直接呼出で起動できることが契約)。`git diff` 再取得は開始時 head 解に一致する
--- 引数形 (通常 = 作業ツリー基準の単引数 / scratch 縮退 = `<base> <head>` /
--- pr = cwd worktree の単引数) -> 再パース -> anchor 検証 -> ±カウント・panel・
--- スレッド・winbar 再適用 -> :diffupdate -> 永続化。
--- in-flight 中の再入は fetch を増やさず dirty マークだけ (完了後追い fetch 1 回、
--- 多重取得しない)。失敗は WARN + 前回 parse 保持 (ディスク・UI・コメント無変更)。
--- close / 切替後はコールバックが active 同一性で結果を破棄する (call 前に確定)。
function M.refresh()
  if active == nil then
    return
  end
  if refresh_inflight then
    refresh_dirty = true
    return
  end
  local current = active
  local session = current.session
  local cwd = session.repo
  local head = nil
  if session.mode == 'pr' then
    cwd = worktree_of(session).path
  elseif current.degraded then
    head = session.head
  end
  refresh_inflight = true
  git_diff.fetch({ base = session.base, head = head, cwd = cwd }, function(res)
    if active ~= current then
      -- close / 切替後の解決: 結果を破棄 (無効化済みの in-flight/dirty を触らない)
      return
    end
    refresh_inflight = false
    local follow = refresh_dirty
    refresh_dirty = false
    if not res.ok then
      local reason = res.code == result.codes.E_REF and usermsg.git_ref_error(res.error)
        or res.error
      notify_warn(
        ('差分の再取得に失敗しました。現在の表示とコメントを保持します: %s'):format(
          reason
        )
      )
      if follow then
        M.refresh() -- まとめられた保存分の再取得は試みる (失敗時のみ再度 WARN)
      end
      return
    end
    apply_refresh(current, res.data.files)
    notify_head_switch_once(current)
    if follow then
      M.refresh()
    end
  end)
end

-- BufWritePost 自動リフレッシュ (diff-review「リフレッシュ」1)。head 窓での保存も、
-- 同一バッファがユーザー窓から書かれたときも同じ buffer イベントなのでグローバル
-- 登録し、コールバックで active とセッション会員を判定して弾く (非レビュー中の
-- 保存は何もしない = ユーザー操作への影響ゼロ。縮退 head の scratch は
-- review:// 名のためセッション員に満たず無視)。
vim.api.nvim_create_autocmd('BufWritePost', {
  desc = 'review.nvim: 保存した差分の自動リフレッシュ',
  callback = function(ev)
    if active == nil then
      return
    end
    if session_file_of(active, ev.buf) == nil then
      return
    end
    M.refresh()
  end,
})

return M
