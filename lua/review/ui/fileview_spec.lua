-- ui/fileview: レビュー tab の外へ実ファイルを開く `o` 経路 (docs/design/features/
-- diff-review.md「操作」o 行 / DESIGN.md キーマップ表)。**前行儀 tab** (レビュー tab
-- の左隣に新 tab を置き、diff ペアを壊さず通常編集文脈へ出る) が契約の中心。
-- 実ファイルが存在すれば git を一切呼ばない編集可 buffer (ユーザーが自分の窓で
-- 開いていれば vim が同一バッファを再利用)。scratch 縮退等で checkout に実文件が
-- 無い file だけ `git show <head>:<path>` read-only scratch に fallback する。
-- b:review_meta / b:review_winbar は実ファイル窓へ置かない (レビュー痕跡や winbar
-- をユーザー窓へ漏らさない — 縮退 scratch 窓は review://file/ 名で識別)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local fileview = require 'review.ui.fileview'

local REAL_NOTIFY = vim.notify
local state = {}

local function tab_index(tab)
  for i, t in ipairs(vim.api.nvim_list_tabpages()) do
    if t == tab then
      return i
    end
  end
  return nil
end

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {} }
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    cli._set_executable(function()
      return 1
    end)
    vim.cmd 'tabnew'
    state.review_tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.review_tab) then
      vim.api.nvim_set_current_tabpage(state.review_tab)
      vim.cmd 'tabclose!'
    end
    -- o で開いた fileview tab が残っていたら閉じる (state.tab 相当の掃除)
    for _ = 1, #vim.api.nvim_list_tabpages() do
      if vim.api.nvim_tabpage_is_valid(state.review_tab) then
        vim.api.nvim_set_current_tabpage(state.review_tab)
        if #vim.api.nvim_list_tabpages() > 1 then
          -- 残 tab を順に閉じるため review tab を最後に残す
          local closed_any = false
          for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if tab ~= state.review_tab and vim.api.nvim_tabpage_is_valid(tab) then
              vim.api.nvim_set_current_tabpage(tab)
              pcall(vim.cmd, 'tabclose!')
              closed_any = true
              break
            end
          end
          if not closed_any then
            break
          end
        else
          break
        end
      else
        break
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name:match '^review://' or name:find('fileview%-spec', 1) ~= nil then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
    vim.notify = REAL_NOTIFY
    cli._set_system(nil)
    cli._set_executable(nil)
    config.reset()
    if state.dir ~= nil then
      vim.fn.delete(state.dir, 'rf')
      state.dir = nil
    end
  end)
end

local function stub_show(stdout, code, stderr)
  state.cmds = {}
  cli._set_system(function(cmd, opts, on_exit)
    table.insert(state.cmds, { cmd = cmd, opts = opts })
    on_exit { code = code or 0, stdout = stdout or '', stderr = stderr or '' }
  end)
end

local function write_file(path, content)
  local f = io.open(path, 'w')
  f:write(content)
  f:close()
end

describe('fileview.open 実ファイル経路 (前行儀 tab)', function()
  use_env()

  local function no_git_stub()
    state.calls = {}
    cli._set_system(function(cmd)
      table.insert(state.calls, cmd)
      error('実ファイル経路で git が呼ばれた: ' .. table.concat(cmd, ' '), 0)
    end)
  end

  it('repo/path の実ファイルを編集可で開き、git 呼び出し 0 件', function()
    no_git_stub()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    state.dir = dir
    local full = vim.fs.joinpath(dir, 'fileview-spec-a.lua')
    write_file(full, 'local x = 1\nsecond\n')

    local err, buf
    fileview.open({
      repo = dir,
      head = 'feature',
      id = 's1',
      path = 'fileview-spec-a.lua',
    }, function(e, b)
      err, buf = e, b
    end)

    assert.is_nil(err)
    assert.equals(0, #state.calls)
    assert.equals(vim.uv.fs_realpath(full), vim.api.nvim_buf_get_name(buf))
    assert.equals('lua', vim.bo[buf].filetype)
    assert.equals(false, vim.bo[buf].readonly)
    assert.equals(true, vim.bo[buf].modifiable)
  end)

  it(
    '新 tab はレビュー tab の前行儀 (レビュー tab は 1 つ右へずれる)',
    function()
      no_git_stub()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      state.dir = dir
      write_file(vim.fs.joinpath(dir, 'fileview-spec-b.lua'), 'x\n')
      local review_nr = vim.fn.tabpagenr()

      fileview.open(
        { repo = dir, head = 'h', id = 's1', path = 'fileview-spec-b.lua' },
        function() end
      )

      assert.equals(review_nr, vim.fn.tabpagenr(), 'フォーカスは新 tab')
      -- 新 tab の位置 = 旧レビュー tab の位置、レビュー tab は右隣へ
      local moved = tab_index(state.review_tab)
      assert.equals(review_nr + 1, moved)
    end
  )

  it('worktree 指定なら repo でなく worktree 基準の実ファイルを開く', function()
    no_git_stub()
    local repo = vim.fn.tempname()
    local wt = vim.fn.tempname()
    vim.fn.mkdir(repo, 'p')
    vim.fn.mkdir(wt, 'p')
    state.dir = repo
    write_file(vim.fs.joinpath(wt, 'fileview-spec-c.lua'), 'from worktree\n')

    local err, buf
    fileview.open({
      repo = repo,
      head = 'review-nvim/pr-7',
      id = 's1',
      path = 'fileview-spec-c.lua',
      worktree = wt,
    }, function(e, b)
      err, buf = e, b
    end)

    assert.is_nil(err)
    assert.same({ 'from worktree' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it(
    'ユーザーが既に開いている実ファイルは同一バッファを再利用する',
    function()
      no_git_stub()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      state.dir = dir
      local full = vim.fs.joinpath(dir, 'fileview-spec-d.lua')
      write_file(full, 'same\n')
      vim.cmd(('tabedit %s'):format(vim.fn.fnameescape(full)))
      local before = vim.fn.bufnr(vim.uv.fs_realpath(full))
      vim.cmd 'tabclose#'

      fileview.open(
        { repo = dir, head = 'h', id = 's1', path = 'fileview-spec-d.lua' },
        function() end
      )

      assert.equals(before, vim.fn.bufnr(vim.uv.fs_realpath(full)))
    end
  )
end)

describe('fileview.open git show fallback', function()
  use_env()

  it(
    'checkout 側に存在しない file は review://file/ read-only scratch を前行儀 tab で開く',
    function()
      stub_show 'old base content\nsecond\n'
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      state.dir = dir
      local review_nr = vim.fn.tabpagenr()

      local err, buf
      fileview.open({ repo = dir, head = 'feature', id = 's1', path = 'gone.lua' }, function(e, b)
        err, buf = e, b
      end)

      assert.is_nil(err)
      assert.same({ 'git', 'show', 'feature:gone.lua' }, state.cmds[1].cmd)
      assert.equals('review://file/s1/gone.lua', vim.api.nvim_buf_get_name(buf))
      assert.same({ 'old base content', 'second' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_true(vim.bo[buf].readonly)
      assert.equals('nofile', vim.bo[buf].buftype)
      local moved = tab_index(state.review_tab)
      assert.equals(review_nr + 1, moved)
    end
  )

  it('fallback 窓は w:review_winbar を持つ (b: は使わない)', function()
    stub_show 'x\n'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    state.dir = dir
    local err, buf
    fileview.open({
      repo = dir,
      head = 'feature',
      id = 's1',
      path = 'gone2.lua',
      winbar = 'feature · gone2.lua · read-only (git show)',
    }, function(e, b)
      err, buf = e, b
    end)
    assert.is_nil(err)
    local win = vim.fn.win_findbuf(buf)[1]
    assert.is_not_nil(win)
    assert.equals('feature · gone2.lua · read-only (git show)', vim.w[win].review_winbar)
    assert.is_nil(vim.b[buf].review_winbar)
  end)

  it('git show 失敗は cb に結果型 err (buffer を作らない)', function()
    stub_show('', 128, 'fatal: path does not exist\n')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    state.dir = dir
    local err
    fileview.open({ repo = dir, head = 'h', id = 's2', path = 'gone3.lua' }, function(e)
      err = e
    end)
    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 128 },
      error = 'fatal: path does not exist',
      code = 'E_GIT',
    }, err)
    assert.equals(-1, vim.fn.bufnr 'review://file/s2/gone3.lua')
  end)

  it(
    'review://file scratch の 2 度目 open は同名バッファ差し替え (窓を増やさない)',
    function()
      stub_show 'v1\n'
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      state.dir = dir
      local first
      fileview.open({ repo = dir, head = 'h', id = 's3', path = 'again.lua' }, function(_, b)
        first = b
      end)
      local tabs_after_first = #vim.api.nvim_list_tabpages()
      stub_show 'v2\n'
      local second
      fileview.open({ repo = dir, head = 'h', id = 's3', path = 'again.lua' }, function(_, b)
        second = b
      end)
      assert.equals(first, second)
      assert.same({ 'v2' }, vim.api.nvim_buf_get_lines(second, 0, -1, false))
      assert.equals(tabs_after_first, #vim.api.nvim_list_tabpages())
    end
  )
end)

describe('fileview.open 実 git', function()
  use_env()

  it('実 repo の checkout 外 ref 内容が read-only fallback で開く', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    state.dir = dir
    local function git(args)
      local out =
        vim.system(vim.list_extend({ 'git' }, args), { cwd = dir, text = true }):wait(10000)
      assert.equals(0, out.code, 'git ' .. table.concat(args, ' '))
    end
    git { 'init', '-q', '-b', 'main' }
    git { 'config', 'user.email', 'spec@example.com' }
    git { 'config', 'user.name', 'spec' }
    write_file(vim.fs.joinpath(dir, 'fileview-spec-real.lua'), 'return 1\n')
    git { 'add', '-A' }
    git { 'commit', '-qm', 'base' }
    git { 'checkout', '-qb', 'feature' }
    write_file(vim.fs.joinpath(dir, 'fileview-spec-real.lua'), 'return 2\n')
    git { 'add', '-A' }
    git { 'commit', '-qm', 'feat' }
    -- main checkout 側では fileview-spec-del.lua が存在しない = fallback 経路
    write_file(vim.fs.joinpath(dir, 'fileview-spec-del.lua'), 'del content\n')
    git { 'add', '-A' }
    git { 'commit', '-qm', 'add' }
    git { 'checkout', '-q', 'main' }

    cli._set_system(nil)
    local buf
    fileview.open(
      { repo = dir, head = 'feature', id = 't', path = 'fileview-spec-del.lua' },
      function(_e, b)
        buf = b
      end
    )
    vim.wait(6000, function()
      return buf ~= nil
    end)
    assert.same({ 'del content' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals('lua', vim.bo[buf].filetype)
    assert.is_true(vim.bo[buf].readonly)
  end)
end)
