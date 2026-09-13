-- セッション開始・切替・終了・削除の調整役 (docs/design/features/diff-review.md
-- 「開始」「開始と既存セッションの継承」/ persistence-restore.md「復元手順」共通部 /
-- pr-worktree.md「worktree 作成判断」「セッションとレビューの終了」「セッションの削除」)。
-- 契約の要点:
--   * 戻り値は同期に判定できる失敗のみ (git を伴う成否は notify / UI で返す)
--   * INV-1: active セッションは高々 1 つ。切替は必ず save -> close を経る
--   * INV-3: worktree を削除してよいのは created_by_us=true の記録のある分だけ
--   * INV-4: CRUD・viewed 切替の直後に store.save (失敗時はメモリ保持 + WARN)
-- 終了手順の順序原則 (pr-worktree.md): ユーザーデータを失いうる操作の判定と確認を、
-- 状態変更より前に行う (close/delete は worktree status -> 確認 -> save/detach -> 掃除)。
local git_diff = require 'review.git.diff'
local git_ref = require 'review.git.ref'
local git_repo = require 'review.git.repo'
local git_worktree = require 'review.git.worktree'
local paths = require 'review.store.paths'
local anchor = require 'review.core.anchor'
local result = require 'review.core.result'
local store = require 'review.store.session'
local ui_chrome = require 'review.ui.chrome'
local ui_diffbuffer = require 'review.ui.diffbuffer'
local ui_fileview = require 'review.ui.fileview'
local ui_list = require 'review.ui.list'
local usermsg = require 'review.handlers.usermsg'

local M = {}

local now = os.time

-- 時刻の境界 (created_at)。テストは固定値を注入する。
function M._set_now(fn)
  now = fn or os.time
end

-- active = { session, files_by_path, file_order, sidebar_buf, sidebar_win,
--            diff_win, diff_bufs = { [path] = bufnr } }
local active = nil
local sidebar_filter = nil -- sidebar 絞り込み (view state、session JSON に載せない)

function M._reset()
  active = nil
  sidebar_filter = nil
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

-- JSON  round-trip 済みの worktree 記録テーブル (無ければ nil)。
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
-- switch 提案 / scratch 縮退で対応する (diff-review「head 解決」、DESIGN 決定表
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

-- window / buffer を掃除して active を外す (save しない。delete 経路用)。
local function detach()
  if active == nil then
    return
  end
  local current = active
  active = nil
  sidebar_filter = nil
  close_buffer(current.sidebar_buf)
  for _, buf in pairs(current.diff_bufs) do
    close_buffer(buf)
  end
  for _, win in ipairs { current.sidebar_win, current.diff_win } do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
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

--- sidebar を現在のセッション状態から再描画し、元の window に載せ直す。
-- sidebar 絞り込みの可視 files。render 側と ]d/[d の進む順が必ず同じ集合を
-- 向くよう、可視一覧はこの 1 関数からのみ供給する (filter は view state で
-- session JSON に載せない — 復元・開き直し後は全一覧が正しい)。
local function visible_files()
  if sidebar_filter == nil or sidebar_filter == '' then
    return active.file_order_sorted
  end
  local needle = sidebar_filter:lower()
  local out = {}
  for _, e in ipairs(active.file_order_sorted) do
    if e.path:lower():find(needle, 1, true) ~= nil then
      out[#out + 1] = e
    end
  end
  return out
end

local function refresh_sidebar()
  active.sidebar_buf =
    ui_list.render_sidebar(active.session, visible_files(), { filter = sidebar_filter })
  if vim.api.nvim_win_is_valid(active.sidebar_win) then
    vim.api.nvim_win_set_buf(active.sidebar_win, active.sidebar_buf)
    ui_chrome.window(active.sidebar_win)
  end
end

--- `/`: sidebar 一覧を絞り込む。空入力 = 解除、キャンセル (Esc) = 現状維持。
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
    refresh_sidebar()
  end)
end

-- diff 役の窓を「有効 + 内容が diff らしい」に揃える。<C-w>o / :q で窓が側に
-- 消えるケースに加え、:buffer 等で**窓 id は生き残ったまま内容だけ差し替わる**
-- drift がある (UX review F1 の真因: id 実体だけ見て set_buf すると、sidebar を
-- 表示中の窓が diff に化けて一覧が失われ、1 窓 UI になる)。役割は window id で
-- なく実際に何を表示しているから導く。
local function diff_win_ok()
  local w = active.diff_win
  if w == nil or not vim.api.nvim_win_is_valid(w) then
    return false
  end
  local b = vim.api.nvim_win_get_buf(w)
  if active.sidebar_buf ~= nil and b == active.sidebar_buf then
    return false -- diff 役の顔に sidebar が乗っている = 役割がずれている
  end
  local name = vim.api.nvim_buf_get_name(b)
  if name:match '^review://' ~= nil then
    return true
  end
  -- 作りたての空窓 (直前の vsplit が確保した diff 役) はそのまま許容する。
  -- ユーザー buffer が乗った窓 (内容あり or 名前あり) だけを drift とみなす。
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  return name == ''
    and vim.bo[b].buftype == ''
    and (#lines == 0 or (#lines == 1 and lines[1] == ''))
end

-- 実際に sidebar buf を見せている窓 (diff 役候補を優先的に除外して探す)
local function sidebar_display_win(exclude)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == active.sidebar_buf and w ~= exclude then
      return w
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == active.sidebar_buf then
      return w
    end
  end
  return nil
end

local function ensure_diff_win()
  if diff_win_ok() then
    return
  end
  local stale_dw = active.diff_win
  local anchor_win = nil
  if active.sidebar_buf ~= nil and vim.api.nvim_buf_is_valid(active.sidebar_buf) then
    anchor_win = sidebar_display_win(stale_dw)
    if anchor_win ~= nil then
      -- 役割を実在窓へ再紐付け (以後の refresh_sidebar も正しい窓を打つ)
      active.sidebar_win = anchor_win
    end
  end
  if anchor_win == nil then
    if stale_dw ~= nil and vim.api.nvim_win_is_valid(stale_dw) then
      anchor_win = stale_dw
    elseif active.sidebar_win ~= nil and vim.api.nvim_win_is_valid(active.sidebar_win) then
      anchor_win = active.sidebar_win
    else
      anchor_win = vim.api.nvim_get_current_win()
    end
  end
  vim.api.nvim_set_current_win(anchor_win)
  vim.cmd 'vsplit'
  -- 新窓は splitleft/splitright の設定次第で左右どちらにも出るので、設計どおり
  -- 「sidebar 左 / diff (再建窓) 右」へ寄せる (UX review: ユーザー環境で一覧が右に
  -- 出て視線移動が GitHub Files changed と逆になった)
  vim.cmd 'wincmd L'
  active.diff_win = vim.api.nvim_get_current_win()
end

-- skip_ensure: open_session_ui 専用 (直前に vsplit で diff 役を確保済み)。
-- vsplit は現窓の buffer を継承するため、中身のある窓が起点だと new 窓も同じ
-- buffer を持ってしまい、drift 判定が二重 split する (開通時は窓の存在自体が
-- 保証されているので判定を迂回する)。
local function render_diff_file(path, skip_ensure)
  if not skip_ensure then
    ensure_diff_win()
  end
  if path == nil then
    -- 復元時に差分がまるごと消滅し、しかもコメント由来の消失ファイルも無いとき
    -- 右ペインは「変更なし」プレースホルダを開く (persistence-restore.md、開くことを拒否しない)。
    local buf = ui_diffbuffer.render_no_changes(active.session, { winid = active.diff_win })
    active.diff_bufs[ui_diffbuffer.NO_DIFF_PATH] = buf
    vim.api.nvim_win_set_buf(active.diff_win, buf)
    ui_chrome.window(active.diff_win)
    return buf
  end
  local file = active.files_by_path[path]
    or { path = path, status = 'M', binary = false, added = 0, deleted = 0, hunks = {} }
  local buf = ui_diffbuffer.render(active.session, file, { winid = active.diff_win })
  active.diff_bufs[path] = buf
  vim.api.nvim_win_set_buf(active.diff_win, buf)
  -- render 後も diff 窓が差し替わる経路 (drift 再 split 等) があるため、buf を
  -- 当てたこの時点で chrome を確実に適用する (set_buf する側が窓の装飾も持つ)。
  ui_chrome.window(active.diff_win)
  return buf
end

-- 開通時に review UI 由緒でない「空の [No Name] 窓」を回収する (UX review F1:
-- list 経由の再開で余剰の空窓がレイアウトに残って迷う症状)。条件は厳しく
-- (無名・buftype 空・modifiable・中身空行・review meta なし・レビュー 2 窓以外)
-- して、内容のある窓や review:// 窓には触れない。
local function sweep_empty_wins()
  local keep = { [active.sidebar_win] = true, [active.diff_win] = true }
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(w) and not keep[w] then
      local b = vim.api.nvim_win_get_buf(w)
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      local empty = #lines == 0 or (#lines == 1 and lines[1] == '')
      if
        vim.api.nvim_buf_get_name(b) == ''
        and vim.bo[b].buftype == ''
        and vim.bo[b].modifiable
        and empty
        and vim.b[b].review_meta == nil
      then
        pcall(vim.api.nvim_win_close, w, false)
      end
    end
  end
end

local function open_session_ui()
  active.sidebar_buf =
    ui_list.render_sidebar(active.session, active.file_order_sorted, { filter = sidebar_filter })
  local sw = vim.api.nvim_get_current_win()
  -- 先に vsplit して diff 役の窓 ([No Name] のまま) を確保し、その後に sidebar を
  -- 流し込む。set_buf から先に入れると vsplit の新窓が sidebar buf を継承して
  -- [No Name] でなくなり、ensure_diff_win の drift 判定が再 split して余剰窓が
  -- 残る (UX review F1 の「余剰の空窓」の正体)。
  vim.cmd 'vsplit'
  vim.cmd 'wincmd L' -- sidebar 左 / diff 右を splitright 設定に依らせない
  active.diff_win = vim.api.nvim_get_current_win()
  active.sidebar_win = sw
  vim.api.nvim_win_set_buf(active.sidebar_win, active.sidebar_buf)
  pcall(vim.api.nvim_win_set_width, active.sidebar_win, 30)
  ui_chrome.window(active.sidebar_win)
  -- 「右ペインには一覧の先頭ファイルの diff を開く」= 一覧はパス昇順なので
  -- sorted 先頭を使う (core/diff の parse 出現順ではない)。
  -- sorted が空 = 差分消滅復元で消失ファイルですらない (nil -> プレースホルダ)。
  local first = active.file_order_sorted[1]
  render_diff_file(first and first.path or nil, true)
  sweep_empty_wins()
end

-- files_by_path から sidebar 用の並びを作る (parse の出現順 = file_order)。
-- args = { repo, id, mode, base, head, pr, info? } (pr-worktree.md「PR 解決」3 の
-- 開始時に handler が組み立てる)。worktree は解決済み値 (記録 | vim.NIL) を受ける。
local function begin_session(args, files, existing, worktree)
  local files_by_path = {}
  local file_order = {}
  for _, file in ipairs(files) do
    files_by_path[file.path] = file
    file_order[#file_order + 1] = file.path
  end

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
  else
    anchor.verify(session.comments, files_by_path)
    if #files == 0 then
      -- 「差分がまるごと消滅」復元: 再取得差分が 0 ファイルなら anchor 照合の
      -- 余地が無いので全コメントを outdated 化する (persistence-restore.md。
      -- anchor 欠損で検証スキップの active を残さない)。
      for _, comment in ipairs(session.comments) do
        comment.state = 'outdated'
      end
    end
  end
  session.status = 'open'
  -- 作成判断の解を毎回上書き (crash 後の記録陳腐化を許さない — pr-worktree.md 異常終了回復)。
  session.worktree = worktree

  -- files = 差分に出る全ファイル + コメントを持つ消失ファイル (outdated 表示先)。
  local old_files = session.files or {}
  local new_files = {}
  for _, path in ipairs(file_order) do
    local old = old_files[path]
    new_files[path] = { viewed = old ~= nil and old.viewed or false }
  end
  for _, comment in ipairs(session.comments) do
    if new_files[comment.file] == nil then
      local old = old_files[comment.file]
      new_files[comment.file] = { viewed = old ~= nil and old.viewed or false }
    end
  end
  session.files = new_files

  local sorted = {}
  for _, file in ipairs(files) do
    sorted[#sorted + 1] = file
  end
  for path in pairs(new_files) do
    if files_by_path[path] == nil then
      sorted[#sorted + 1] = {
        path = path,
        status = 'M',
        binary = false,
        added = 0,
        deleted = 0,
        hunks = {},
        -- 今回の差分に現れない消失ファイル (outdated コメントの表示先)。
        -- diff バッファは「変更なし」を描画する。
        vanished = true,
      }
      files_by_path[path] = sorted[#sorted]
    end
  end
  -- 一覧の先頭 = 右ペイン既定のファイルなので、pairs 順のまま繋ぐと復元経路だけ順序が揺れる。
  table.sort(sorted, function(a, b)
    return a.path < b.path
  end)

  -- 開き直し = 全一覧が正しい (前回の絞り込みを持ち込まない)
  sidebar_filter = nil
  active = {
    session = session,
    files_by_path = files_by_path,
    file_order = file_order,
    file_order_sorted = sorted,
    sidebar_buf = nil,
    sidebar_win = nil,
    diff_win = nil,
    diff_bufs = {},
  }
  persist()
  open_session_ui()
  if args.info ~= nil then
    -- PR タイトルは開始時 INFO のみ (セッションに永続化しない — pr-worktree.md)。
    vim.notify('review.nvim: ' .. args.info, vim.log.levels.INFO)
  end
end

-- ============================================================================
-- head 解決フロー (branch のみ / docs/design/DESIGN.md 決定表「head が現在の
-- HEAD と違うとき」/ docs/design/features/diff-review.md「入出力と振る舞い」2)
-- ============================================================================

-- 縮退の確定文言 (diff-review「開始」2 «…» の通り。UI に触れないこの issue でも
-- 通知では確定形を使う)。
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
    begin_session(args, res.data.files, existing, res.data.worktree)
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
          .. ' コメント内容も引き継ぎます [y/N]: '
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
      -- detached HEAD は literal "HEAD" がそのまま返る (保存後も同じ解決経路で复原可)
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

--- diff / sidebar の q キー。:Review close と同一。
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

--- sidebar <CR>: 右ペインをそのファイルの diff に差し替え、viewed=true + save。
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
  local path = ui_list.row_file(buf, row)
  if path == nil then
    return
  end
  local entry = active.session.files[path]
  if entry == nil then
    entry = { viewed = false }
    active.session.files[path] = entry
  end
  entry.viewed = true
  render_diff_file(path)
  -- 「そのファイルの diff へ移動」の語感どおり focus を diff へ送る。
  -- sidebar に残ったままだと直後の c/e/y が一覧側に該当作用を持たず無反応に
  -- 見える (UX review F12)。
  vim.api.nvim_set_current_win(active.diff_win)
  persist()
  refresh_sidebar()
end

--- コメント CRUD 直後の再永続化 + 表示更新 (INV-4、diff-review「右ペインは
--- 状態から再構成」)。開いている diff バッファのみ再 render する。
function M.commit_comment_change()
  if active == nil then
    return
  end
  persist()
  for path, buf in pairs(active.diff_bufs) do
    if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
      if path == ui_diffbuffer.NO_DIFF_PATH then
        ui_diffbuffer.render_no_changes(active.session)
      else
        local file = active.files_by_path[path]
          or { path = path, status = 'M', binary = false, added = 0, deleted = 0, hunks = {} }
        ui_diffbuffer.render(active.session, file, {})
      end
    end
  end
end

--- 読み込み済みセッションを new 側差分とともに開始処理へ引き継ぐ (restore ルート:
--- anchor 検証 -> files map 再構築 -> UI -> open save)。worktree の解決は
--- fetch_prepared 側で済んでいるため、解 (記録 | vim.NIL) を受ける。
--- 復元時の head 解決 (switch 提案 / scratch 縮退) も fetch_prepared が走る
--- (DESIGN.md 決定表「起動時復元」)。
function M.resume_into(session, files, worktree)
  begin_session({
    repo = session.repo,
    id = session.id,
    mode = session.mode,
    base = session.base,
    head = session.head,
    pr = session.pr,
  }, files, session, worktree)
end

-- 現在 diff バッファの path (meta.kind=diff のとき)。NO_DIFF プレースホルダは
-- 一覧に無いので「先頭扱い」の根拠に使う。
local function current_diff_path()
  local meta = vim.b[vim.api.nvim_get_current_buf()].review_meta or {}
  if meta.kind == 'diff' then
    return meta.path
  end
  return nil
end

-- ]d / [d: 一覧 (パス昇順) を辿って右ペインのファイルを進める/戻す。
-- 処理は sidebar <CR> と同一 (viewed=true + save + 再描画)。focus は diff 窓に
-- 留まる (キーを押している場所が diff なので移動先も diff = [c/]c と同じ感覚)。
-- 端では何もしない (]c が最終 hunk で止まる標準と同じ)。
local function step_file(delta)
  if active == nil then
    return
  end
  local order = {}
  for _, e in ipairs(visible_files()) do
    order[#order + 1] = e.path
  end
  if #order == 0 then
    return
  end
  local cur = current_diff_path()
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
  local path = order[ni]
  local entry = active.session.files[path]
  if entry == nil then
    entry = { viewed = false }
    active.session.files[path] = entry
  end
  entry.viewed = true
  render_diff_file(path)
  persist()
  refresh_sidebar()
end

--- `]d`: 次のファイルへ。
function M.next_file()
  step_file(1)
end

--- `[d`: 前のファイルへ。
function M.prev_file()
  step_file(-1)
end

--- `S`: sidebar (変更ファイル一覧) へ focus を移す。一覧窓が側から閉じられて
--- いた場合は diff 窓の隣 (左) に再建する (回線の向きは設計どおり sidebar 左)。
function M.focus_sidebar()
  if active == nil then
    return
  end
  -- sidebar buf は scratch (bufhidden=wipe) で、表示窓が閉じられると消える
  -- (only / :bdelete 経由)。その場合は状態から描き直して作り直す。
  if active.sidebar_buf == nil or not vim.api.nvim_buf_is_valid(active.sidebar_buf) then
    active.sidebar_buf =
      ui_list.render_sidebar(active.session, visible_files(), { filter = sidebar_filter })
    active.sidebar_win = nil
  end
  local sw = nil
  if active.sidebar_win ~= nil and vim.api.nvim_win_is_valid(active.sidebar_win) then
    sw = active.sidebar_win
  end
  local shows_sb = sw ~= nil and vim.api.nvim_win_get_buf(sw) == active.sidebar_buf
  if not shows_sb then
    sw = sidebar_display_win(nil)
    shows_sb = sw ~= nil
  end
  if shows_sb then
    active.sidebar_win = sw
    vim.api.nvim_set_current_win(sw)
    return
  end
  local sb_anchor
  if active.diff_win ~= nil and vim.api.nvim_win_is_valid(active.diff_win) then
    sb_anchor = active.diff_win
  else
    sb_anchor = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(sb_anchor)
  vim.cmd 'vsplit'
  vim.cmd 'wincmd H'
  active.sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(active.sidebar_win, active.sidebar_buf)
  pcall(vim.api.nvim_win_set_width, active.sidebar_win, 30)
  ui_chrome.window(active.sidebar_win)
end

--- `o`: 現在バッファ (diff / sidebar) に行っているファイルの実体を開く。
--- worktree あり = worktree 基準の実ファイル (編集可) / なし = git show read-only
--- (ui/fileview)。削除ファイルと diff 削除行 (new 側に無い) はコンテキストへ
--- 寄せず WARN (pr-worktree.md「実ファイル参照」)。
function M.open_file_current()
  if active == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local meta = vim.b[buf].review_meta or {}
  local path
  local row = vim.api.nvim_win_get_cursor(win)[1]
  if meta.kind == 'diff' then
    path = meta.path
    -- その行が new 側に無い (削除行) = 対応するファイル行が存在しない。
    -- コンテキストへ寄せず WARN (pr-worktree.md「実ファイル参照」)。
    if ui_diffbuffer.row_is_deleted(buf, row) then
      notify_warn '削除行の上のためファイルを開けません (new 側に該当行がありません)'
      return
    end
  elseif meta.kind == 'sidebar' then
    path = ui_list.row_file(buf, row)
  else
    notify_warn 'diff / sidebar バッファではありません'
    return
  end
  if path == nil then
    return
  end
  local file = active.files_by_path[path]
  if file ~= nil and file.status == 'D' then
    notify_warn(('削除ファイル %s は開けません'):format(path))
    return
  end
  local wt = worktree_of(active.session)
  ui_fileview.open({
    repo = active.session.repo,
    head = active.session.head,
    id = active.session.id,
    path = path,
    win = win,
    -- worktree ありなら worktree 基準の実ファイル (編集可)。記録があっても
    -- dir が無い場合は従来経路 (git show) に倒すと古い head 内容を取り違えるため
    -- fileview 側の stat 失敗として WARN 通知になる。
    worktree = wt ~= nil and wt.path or nil,
    -- read-only 参照窓だけ winbar 文言を出す (編集可の窓はユーザーのファイル)。
    winbar = wt == nil and ('%s..%s · %s · read-only (git show)'):format(
      active.session.base or '',
      active.session.head or '',
      path
    ) or nil,
  }, function(err)
    if err ~= nil then
      notify_warn(err.error)
    end
  end)
end

--- sidebar x: viewed 切替 -> 直後に save (INV-4)。
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
  local path = ui_list.row_file(buf, row)
  if path == nil then
    return
  end
  local entry = active.session.files[path] or { viewed = false }
  entry.viewed = not entry.viewed
  active.session.files[path] = entry
  persist()
  refresh_sidebar()
end

return M
