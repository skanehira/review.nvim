-- spec 共有: handlers/session*_spec の開始部品 (session_spec を分割した各ファイルが
-- 共有する定数・git 応答・開始ヘルパー・use_env)。
-- state は spec 本体と同一テーブルで、use_env の before_each が in-place で初期化する
-- (spec 側は `local state = sf.state` で受け、state.xxx を直接読む)。
local config = require 'review.config'
local nvim_env = require 'helpers.nvim_env'
local paths = require 'review.store.paths'
local session_env = require 'helpers.session_env'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'
local git_stub = require 'helpers.git_stub'

local M = {}

local SLUG = 'main--feature'

local SIDEBAR_NAME = 'review://sidebar/' .. SLUG

local RAW_DIFF_A_B = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1 +1,2 @@',
  ' line1',
  '+line2',
  'diff --git a/b.lua b/b.lua',
  'new file mode 100644',
  'index 0000000..3333333',
  '--- /dev/null',
  '+++ b/b.lua',
  '@@ -0,0 +1 @@',
  '+b1',
  '',
}, '\n')

-- spec 本体と同一テーブルを共有する (use_env が in-place で初期化する)。
local state = {}
M.state = state

-- cli._set_system 注入: 実行順に responses[idx] を同期 for on_exit を呼ぶ。
-- state.git_opts[idx] には vim.system opts を並列記録し、cwd 契約を pin できるように
-- する。show は既定応答 (base / 縮退 head scratch 充填) を用意し、open_file 由来の
-- git show が応答不足で error にならないようにする (明示列挙も可能)。
-- gh api (PR 開始時のコメント取り込み pr-comments)。git/worktree の引数組み立てを
-- 対象とする本 spec では GET 一覧系を空応答で通し、call 記録にも応答 index にも
-- 含めない (fetch 完了の通知も 0 件で出ない)。取り込み自体の検証は
-- pr_comments_spec が担う。
local function install_git(responses)
  git_stub.install_queue(state, responses, { gh_api_empty = true })
end

-- install_git の非同期版。defer_pred(cmd) が真の git (worktree remove や
-- git -C <wt> status など) に限って on_exit を state.deferred に捕捉して
-- 呼ばない (実 vim.system は非同期。install_git の同期 on_exit では区別できない
-- 「完了前/後」の挟み込み・順序を pin する)。responses の該当スロットは手前へ
-- 返るため読まれない (placeholder で可)。
local function install_git_deferred(responses, defer_pred)
  git_stub.install_queue(state, responses, { gh_api_empty = true, defer = defer_pred })
end

local function install_git_deferred_remove(responses)
  install_git_deferred(responses, function(cmd)
    return cmd[2] == 'worktree' and cmd[3] == 'remove'
  end)
end

local top_ok = function()
  return { code = 0, stdout = state.repo .. '\n', stderr = '' }
end

local diff_ok = function(stdout)
  return { code = 0, stdout = stdout, stderr = '' }
end

local function load_saved(id)
  return store.load(state.repo, id or SLUG).data
end

local function json_path(id)
  return paths.session_file(state.repo, id or SLUG)
end

local function existing_stub(overrides)
  local s = {
    version = 1,
    id = SLUG,
    repo = state.repo,
    mode = 'branch',
    base = 'main',
    head = 'feature',
    pr = vim.NIL,
    worktree = vim.NIL,
    status = 'closed',
    files = {},
    comments = {},
    created_at = 1,
    updated_at = 1,
  }
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

-- paths.worktree_path は注入済み data dir を使うので require 時でなく呼ぶ時に計算。
local function wt_path(slug)
  return paths.worktree_path(state.repo, slug or SLUG)
end

local function git_fail(msg)
  return function()
    return { code = 255, stdout = '', stderr = msg }
  end
end

local function has_call(prefix)
  for _, cmd in ipairs(state.git_calls) do
    if table.concat(cmd, ' '):sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- file panel (既定 tree) の行はヘッダで揺れるので、entry 写像で行を探す
-- (行番号ハードコードは tree/list 切替・ヘッダ仕様に结合しすぎ、焦点がぼやける)。
local function panel_row_for_buf(buf, kind, path)
  local filepanel = require 'review.ui.filepanel'
  for row = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = filepanel.row_entry(buf, row)
    if entry ~= nil and entry.kind == kind and entry.path == path then
      return row
    end
  end
  return nil
end

local function panel_row_for(kind, path)
  return panel_row_for_buf(vim.api.nvim_win_get_buf(ui_windows.win 'panel'), kind, path)
end

local function focus_panel_file(needle)
  local pw = ui_windows.win 'panel'
  local row = panel_row_for_buf(vim.api.nvim_win_get_buf(pw), 'file', needle)
  assert.is_not_nil(row, 'panel 行が見つからない: ' .. needle)
  vim.api.nvim_set_current_win(pw)
  vim.api.nvim_win_set_cursor(pw, { row, 0 })
end

-- active セッションへコメントを 1 件注入し commit_comment_change (INV-4 save +
-- 表示再構成) まで通す (handlers/comments の UI 往復を待たない最小注入。
-- file / line は開始時 head 実ファイル a.lua の解ける位置)。
local function inject_comment(body, file, line)
  local sess = session_handler.active()
  sess.comments[#sess.comments + 1] = {
    id = 'c' .. (#sess.comments + 1),
    file = file or 'a.lua',
    line = line or 2,
    end_line = line or 2,
    body = body,
    anchor = { before = 'line1', line = 'line2', after = vim.NIL },
    state = 'active',
    created_at = 100,
  }
  session_handler.commit_comment_change()
end

-- 位置を解けない outdated (state=outdated 確定) を 1 件注入し commit_comment_change
-- (save + 表示再構成) まで通す。集約先 head 窓の無いファイル (告知 / 差分消失) の
-- panel winbar ⚠N 検証用 (persistence-restore「anchor 検証」)。
local function inject_outdated(body, file)
  local sess = session_handler.active()
  sess.comments[#sess.comments + 1] = {
    id = 'c' .. (#sess.comments + 1),
    file = file,
    line = 2,
    end_line = 2,
    body = body,
    anchor = { before = vim.NIL, line = 'ghost text', after = vim.NIL },
    state = 'outdated',
    created_at = 100,
  }
  session_handler.commit_comment_change()
end

-- plenary busted は describe 外のフックを持たないため helper 経由で登録する。
local function use_env()
  before_each(function()
    config.reset()
    for k in pairs(state) do
      state[k] = nil
    end
    state.notifications = {}
    state.inputs = {}
    state.input_answer = 'y'
    -- head 実ファイル窓の経路 (:edit 相当) はディスク実在が前提なので repo を作る
    session_env.make_dirs(state, {
      ['a.lua'] = 'line1\nline2\n',
      ['b.lua'] = 'line1\nline2\n',
      ['c.lua'] = 'line1\nline2\n',
      ['bin.dat'] = 'line1\nline2\n',
    })
    state.cwd0 = vim.uv.cwd()
    session_env.inject_store(state)
    session_env.capture_notify(state, true)
    session_env.answer_input(state)
    -- review://* とレビュー tab は nvim プロセス共有。前テスト残りを掃除して
    -- 隔離 tab を現在の tab にする (同名再利用の混線防止)。
    session_env.reset_windows()
    nvim_env.close_all_tabs()
    nvim_env.wipe_review_buffers()
    nvim_env.isolate_tab(state)
  end)
  after_each(function()
    session_env.reset_windows()
    nvim_env.close_all_tabs()
    nvim_env.wipe_review_buffers()
    -- 555 化された残骸 dir を含めて掃除できるよう権限を戻す (chmod テスト側でも
    -- 戻すが、失敗経路の取りこぼし対策)
    pcall(vim.fn.system, { 'chmod', '-R', '755', state.dir })
    session_env.release(state)
  end)
end

-- head / base 解決系の共通応答部品
local SAME_SHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

local OTHER_SHA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

local RP_HEAD_MATCH = {
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
}

local RP_HEAD_MISMATCH = {
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = OTHER_SHA .. '\n', stderr = '' }
  end,
}

local git_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end

local showref_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end

local status_clean = function()
  return { code = 0, stdout = '', stderr = '' }
end

-- 開始を完結させる (head == 現在のチェックアウト / 先頭ファイル a.lua の
-- base = git show 充填まで)。
local function start_done(base, head)
  install_git {
    top_ok,
    RP_HEAD_MATCH[1],
    RP_HEAD_MATCH[2],
    function()
      return diff_ok(RAW_DIFF_A_B)
    end,
    function(cmd)
      assert.same({ 'git', 'show', 'main:a.lua' }, cmd)
      return { code = 0, stdout = 'line1\nline2\n', stderr = '' }
    end,
  }
  return session_handler.start { base = base, head = head }
end

-- worktree 作成判断は mode=pr のみ。pr 開始は add/再利用 -> diff (cwd=worktree、
-- 単引数) の順 (pr-worktree.md「PR 解決」3)。handlers/pr と同じ入口 (session.begin)。
local function begin_pr(responses, opts)
  install_git(responses)
  return session_handler.begin {
    repo = state.repo,
    id = (opts and opts.id) or SLUG,
    mode = 'pr',
    base = 'main',
    head = (opts and opts.head) or 'feature',
  }
end

-- worktree 作成済み (記録 {path=wt_path(), created_by_us=true}) のセッションを開始。
local function started_with_worktree()
  begin_pr {
    git_ok, -- worktree add (stub なので dir は作られない: dir 前提の検証は各自 mkdir)
    function()
      return diff_ok(RAW_DIFF_A_B)
    end,
  }
end

local DEGRADED_MSG = {
  msg = 'review.nvim: the head state is not checked out; reviewing via a read-only scratch',
  level = vim.log.levels.INFO,
}

M.SLUG = SLUG
M.SIDEBAR_NAME = SIDEBAR_NAME
M.RAW_DIFF_A_B = RAW_DIFF_A_B
M.install_git = install_git
M.install_git_deferred = install_git_deferred
M.install_git_deferred_remove = install_git_deferred_remove
M.top_ok = top_ok
M.diff_ok = diff_ok
M.load_saved = load_saved
M.json_path = json_path
M.existing_stub = existing_stub
M.wt_path = wt_path
M.git_fail = git_fail
M.has_call = has_call
M.panel_row_for_buf = panel_row_for_buf
M.panel_row_for = panel_row_for
M.focus_panel_file = focus_panel_file
M.inject_comment = inject_comment
M.inject_outdated = inject_outdated
M.use_env = use_env
M.SAME_SHA = SAME_SHA
M.OTHER_SHA = OTHER_SHA
M.RP_HEAD_MATCH = RP_HEAD_MATCH
M.RP_HEAD_MISMATCH = RP_HEAD_MISMATCH
M.git_ok = git_ok
M.showref_ok = showref_ok
M.status_clean = status_clean
M.start_done = start_done
M.begin_pr = begin_pr
M.started_with_worktree = started_with_worktree
M.DEGRADED_MSG = DEGRADED_MSG

return M
