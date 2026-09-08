-- ui/fileview: `o` の read-only 実ファイル参照 (worktree なし分岐 = git show)。
-- git 注入スタブ + 実 git 1 ケースで、バッファ内容 / read-only / filetype 検出 /
-- 失敗 WARN を検証する。
local cli = require 'review.git.cli'
local config = require 'review.config'
local fileview = require 'review.ui.fileview'

local REAL_NOTIFY = vim.notify

local state = {}

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
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.notify = REAL_NOTIFY
    cli._set_system(nil)
    cli._set_executable(nil)
    config.reset()
  end)
end

local function stub_show(stdout, code, stderr)
  state.cmds = {}
  cli._set_system(function(cmd, opts, on_exit)
    table.insert(state.cmds, { cmd = cmd, opts = opts })
    on_exit { code = code or 0, stdout = stdout or '', stderr = stderr or '' }
  end)
end

describe('fileview.open (git show read-only 経路)', function()
  use_env()

  it('git show <head>:<path> を read-only scratch + vsplit で開く', function()
    stub_show 'one\ntwo\n'
    local received_err, received_buf
    fileview.open(
      { repo = '/repo', head = 'feature', id = 'main--feature', path = 'a.txt' },
      function(e, b)
        received_err, received_buf = e, b
      end
    )

    assert.is_nil(received_err)
    local buf = received_buf
    assert.equals('review://file/main--feature/a.txt', vim.api.nvim_buf_get_name(buf))
    assert.same({ 'one', 'two' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].readonly)
    assert.is_false(vim.bo[buf].modifiable)
    assert.equals('nofile', vim.bo[buf].buftype)
    assert.same(
      { kind = 'fileview', session_id = 'main--feature', path = 'a.txt', head = 'feature' },
      vim.b[buf].review_meta
    )
    -- 実行コマンド
    assert.same({ 'git', 'show', 'feature:a.txt' }, state.cmds[1].cmd)
    assert.equals('/repo', state.cmds[1].opts.cwd)
    -- 右 split に表示された
    assert.is_true(#vim.api.nvim_tabpage_list_wins(state.tab) >= 2)
  end)

  it('.lua 拡張は detected filetype が付く', function()
    stub_show 'local x = 1\n'
    fileview.open({ repo = '/r', head = 'h', id = 'z', path = 'foo.lua' }, function() end)
    assert.equals('lua', vim.bo[vim.fn.bufnr 'review://file/z/foo.lua'].filetype)
  end)

  it('git 失敗は cb に結果型 err が渡り WARN 相当の error を carrying', function()
    stub_show('', 128, 'fatal: path does not exist\n')
    local err
    fileview.open({ repo = '/r', head = 'h', id = 'z', path = 'gone.txt' }, function(e)
      err = e
    end)
    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 128 },
      error = 'fatal: path does not exist',
      code = 'E_GIT',
    }, err)
    assert.equals(-1, vim.fn.bufnr 'review://file/z/gone.txt')
  end)

  it(
    '再 open は同名バッファへ再取得内容进行差し替える (窓を増やさない)',
    function()
      stub_show 'v1\n'
      local first_buf
      fileview.open({ repo = '/r', head = 'h', id = 'z', path = 'a.txt' }, function(_, b)
        first_buf = b
      end)
      stub_show 'v2\n'
      local second_buf, wins_after
      fileview.open({ repo = '/r', head = 'h', id = 'z', path = 'a.txt' }, function(_, b)
        second_buf = b
      end)
      wins_after = #vim.api.nvim_tabpage_list_wins(state.tab)
      assert.equals(first_buf, second_buf)
      assert.same({ 'v2' }, vim.api.nvim_buf_get_lines(second_buf, 0, -1, false))
      assert.equals(2, wins_after)
    end
  )
end)

describe('fileview.open 実 git', function()
  use_env()

  it('実 repo の feature:a.lua 内容が read-only で開く', function()
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
    local f = io.open(vim.fs.joinpath(dir, 'a.lua'), 'w')
    f:write 'return 1\n'
    f:close()
    git { 'add', '-A' }
    git { 'commit', '-qm', 'base' }
    git { 'checkout', '-qb', 'feature' }
    local f2 = io.open(vim.fs.joinpath(dir, 'a.lua'), 'w')
    f2:write 'return 2\n'
    f2:close()
    git { 'add', '-A' }
    git { 'commit', '-qm', 'feat' }

    cli._set_system(nil) -- 本物を使う
    local received_buf
    fileview.open({ repo = dir, head = 'feature', id = 't', path = 'a.lua' }, function(_e, b)
      received_buf = b
    end)
    vim.wait(6000, function()
      return received_buf ~= nil
    end)

    local buf = vim.fn.bufnr 'review://file/t/a.lua'
    assert.not_equals(-1, buf)
    assert.same({ 'return 2' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals('lua', vim.bo[buf].filetype)
    assert.is_true(vim.bo[buf].readonly)
  end)
end)
