-- セッション開始・切替・終了・削除の調整役 (docs/design/features/diff-review.md
-- 「開始」「開始と既存セッションの継承」/ persistence-restore.md「復元手順」共通部)。
-- 契約の要点:
--   * 戻り値は同期に判定できる失敗のみ (git を伴う成否は notify / UI で返す)
--   * INV-1: active セッションは高々 1 つ。切替は必ず save -> close を経る
--   * INV-4: CRUD・viewed 切替の直後に store.save (失敗時はメモリ保持 + WARN)
-- worktree は #6 の拡張。mode=branch / worktree=nil の分岐のみをここで実装する。
local git_diff = require 'review.git.diff'
local git_ref = require 'review.git.ref'
local paths = require 'review.store.paths'
local anchor = require 'review.core.anchor'
local result = require 'review.core.result'
local store = require 'review.store.session'
local ui_diffbuffer = require 'review.ui.diffbuffer'
local ui_fileview = require 'review.ui.fileview'
local ui_list = require 'review.ui.list'

local M = {}

local now = os.time

-- 時刻の境界 (created_at)。テストは固定値を注入する。
function M._set_now(fn)
  now = fn or os.time
end

-- active = { session, files_by_path, file_order, sidebar_buf, sidebar_win,
--            diff_win, diff_bufs = { [path] = bufnr } }
local active = nil

function M._reset()
  active = nil
end

--- 起動中のセッション (UI が開いているもの)。無ければ nil (INV-1 で高々 1)。
function M.active()
  return active and active.session or nil
end

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

-- [y/N] の確認。vim.ui.input を使う (vim.fn.confirm は headless で絞込めない)。
local function confirm(prompt, cb)
  vim.ui.input({ prompt = prompt }, function(answer)
    cb(answer == 'y')
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

-- :Review close 相当。status=closed で save してから UI を閉じる。
-- worktree クリーンアップ分岐は #6 (worktree は常に nil を扱う)。
local function close_saved()
  local current = active
  if current == nil then
    return
  end
  current.session.status = 'closed'
  local res = store.save(current.session)
  detach()
  if not res.ok then
    notify_warn(res.error)
  end
end

--- sidebar を現在のセッション状態から再描画し、元の window に載せ直す。
local function refresh_sidebar()
  active.sidebar_buf = ui_list.render_sidebar(active.session, active.file_order_sorted)
  if vim.api.nvim_win_is_valid(active.sidebar_win) then
    vim.api.nvim_win_set_buf(active.sidebar_win, active.sidebar_buf)
  end
end

local function render_diff_file(path)
  if path == nil then
    -- 復元時に差分がまるごと消滅し、しかもコメント由来の消失ファイルも無いとき
    -- 右ペインは「変更なし」プレースホルダを開く (persistence-restore.md、開くことを拒否しない)。
    local buf = ui_diffbuffer.render_no_changes(active.session, { winid = active.diff_win })
    active.diff_bufs[ui_diffbuffer.NO_DIFF_PATH] = buf
    if vim.api.nvim_win_is_valid(active.diff_win) then
      vim.api.nvim_win_set_buf(active.diff_win, buf)
    end
    return buf
  end
  local file = active.files_by_path[path]
    or { path = path, status = 'M', binary = false, added = 0, deleted = 0, hunks = {} }
  local buf = ui_diffbuffer.render(active.session, file, { winid = active.diff_win })
  active.diff_bufs[path] = buf
  if vim.api.nvim_win_is_valid(active.diff_win) then
    vim.api.nvim_win_set_buf(active.diff_win, buf)
  end
  return buf
end

local function open_session_ui()
  active.sidebar_buf = ui_list.render_sidebar(active.session, active.file_order_sorted)
  active.sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(active.sidebar_win, active.sidebar_buf)
  pcall(vim.api.nvim_win_set_width, active.sidebar_win, 30)
  vim.cmd 'vsplit'
  active.diff_win = vim.api.nvim_get_current_win()
  -- 「右ペインには一覧の先頭ファイルの diff を開く」= 一覧はパス昇順なので
  -- sorted 先頭を使う (core/diff の parse 出現順ではない)。
  -- sorted が空 = 差分消滅復元で消失ファイルですらない (nil -> プレースホルダ)。
  local first = active.file_order_sorted[1]
  render_diff_file(first and first.path or nil)
end

-- files_by_path から sidebar 用の並びを作る (parse の出現順 = file_order)。
local function begin_session(repo, base, head, files, existing)
  local files_by_path = {}
  local file_order = {}
  for _, file in ipairs(files) do
    files_by_path[file.path] = file
    file_order[#file_order + 1] = file.path
  end

  local session = existing
  if session == nil then
    session = {
      id = paths.branch_slug(base, head),
      repo = repo,
      mode = 'branch',
      base = base,
      head = head,
      pr = vim.NIL,
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
end

local function fetch_and_begin(repo, base, head, existing)
  git_diff.fetch({ base = base, head = head, cwd = repo }, function(res)
    if not res.ok then
      notify_warn(res.error)
      return
    end
    if #res.data.files == 0 then
      vim.notify(
        ('review.nvim: 変更なし (%s..%s): レビュー対象がありません'):format(
          base,
          head
        ),
        vim.log.levels.INFO
      )
      return
    end
    begin_session(repo, base, head, res.data.files, existing)
  end)
end

-- 衝突 / 切替 / 継承の確認を消化して fetch へ進む。
local function proceed(repo, base, head)
  local slug = paths.branch_slug(base, head)
  if active ~= nil and active.session.id == slug then
    vim.notify(
      ('review.nvim: %s のレビューは既に開いています'):format(slug),
      vim.log.levels.INFO
    )
    return
  end
  local existing = store.load(repo, slug).data
  if existing ~= nil and paths.slug_conflict(existing, base, head) then
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
    fetch_and_begin(repo, base, head, inherit and existing or nil)
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
            close_saved()
            go(true)
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
          close_saved()
          go(false)
        end
      end
    )
    return
  end
  go(false)
end

local function head_candidates(branches, tags)
  local out = {}
  for _, name in ipairs(branches) do
    out[#out + 1] = name
  end
  for _, name in ipairs(tags) do
    out[#out + 1] = name
  end
  return out
end

-- head 選択の補完候補 (branches -> tags の順。diff-review.md「開始」手順 1)。
local head_names

--- 補完関数の Lua 実体。グローバル Vim script 関数 ReviewNvimHeadComplete が
--- luaeval 経由で呼ぶ (input() は opts の Lua 関数を受理しないため、
--- completion='customlist,{関数名}' の文字形式が唯一の入力経路 —
--- DESIGN.md「既知の制約」)。
function M.complete_head(arglead, _cmdline, _cursorpos)
  local lead = arglead or ''
  local out = {}
  for _, name in ipairs(head_names or {}) do
    if name:sub(1, #lead) == lead then
      out[#out + 1] = name
    end
  end
  return out
end

-- input() が customlist で解決できる「名前のついた」グローバル Vim script 関数を
-- 定義し直す (`:function!`)。luaeval 橋渡しは全対応バージョンにある機構で、
-- opts に Lua 関数を混ぜないことが E467 回避の要点。
local function ensure_head_completer()
  vim.cmd [[
function! ReviewNvimHeadComplete(arglead, cmdline, cursorpos) abort
  return luaeval(
    \ "require('review.handlers.session').complete_head(_A[1], _A[2], _A[3])",
    \ [a:arglead, a:cmdline, a:cursorpos])
endfunction
]]
end

local function select_head(repo, base)
  git_ref.branches({ cwd = vim.fn.getcwd() }, function(bres)
    if not bres.ok then
      notify_warn(bres.error)
      return
    end
    git_ref.tags({ cwd = vim.fn.getcwd() }, function(tres)
      if not tres.ok then
        notify_warn(tres.error)
        return
      end
      head_names = head_candidates(bres.data, tres.data)
      ensure_head_completer()
      vim.ui.input({
        prompt = ('%s.. (review head): '):format(base),
        completion = 'customlist,ReviewNvimHeadComplete',
      }, function(head)
        if head == nil or head == '' then
          return
        end
        proceed(repo, base, head)
      end)
    end)
  end)
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

--- `:Review start <base> [head]` の開始。戻り値はディスパッチ受理
--- (git 成否は非同期 notify / UI、base 欠損だけ同期 err)。
function M.start(opts)
  if type(opts) ~= 'table' or opts.base == nil or opts.base == '' then
    return result.err(
      'review.nvim: :Review start <base> [head] の形式で指定してください',
      nil
    )
  end
  with_repo_top(function(repo)
    if opts.head ~= nil and opts.head ~= '' then
      proceed(repo, opts.base, opts.head)
    else
      select_head(repo, opts.base)
    end
  end)
  return result.ok()
end

--- `:Review close` / q。コメント 0 件なら無確認で閉じる。
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
          close_saved()
        end
      end
    )
  else
    close_saved()
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

--- `:Review delete <id>`。確認 -> (active なら close 相当の掃除) -> JSON 削除。
--- worktree 掃除分岐は #6。
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
        if active ~= nil and active.session.id == id then
          detach()
        end
        local res = store.delete(repo, id)
        if not res.ok then
          notify_warn(res.error)
        end
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

--- 確認なしで active を閉じる (save する)。復元 / 一覧からの再開フローが
--- 事前確認済みの後に呼ぶ。
function M.force_close()
  close_saved()
end

--- 読み込み済みセッションを new 側差分とともに開始処理へ引き継ぐ
--- (restore ルート: anchor 検証 -> files map 再構築 -> UI -> open save)。
function M.resume_into(session, files)
  begin_session(session.repo, session.base, session.head, files, session)
end

--- `o`: 現在バッファ (diff / sidebar) に行っているファイルの実体を開く。
--- worktree 分岐は #6 — ここでは git show の read-only 経路 (fileview)。
--- 削除ファイルは不可通知。
function M.open_file_current()
  if active == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local meta = vim.b[buf].review_meta or {}
  local path
  if meta.kind == 'diff' then
    path = meta.path
  elseif meta.kind == 'sidebar' then
    local row = vim.api.nvim_win_get_cursor(win)[1]
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
  ui_fileview.open({
    repo = active.session.repo,
    head = active.session.head,
    id = active.session.id,
    path = path,
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
