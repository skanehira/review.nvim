-- git/ref: branch / tag 列挙と rev-parse の git 実行アダプタ
-- (diff-review.md「開始」head 選択の補完と ref 検証用)。
-- 引数組み立てと結果型分岐は注入 system スタブ、実 git 経路を 1 ケース。
local ref = require 'review.git.ref'
local cli = require 'review.git.cli'
local config = require 'review.config'

local created_dirs = {}

local function restore_after_each()
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    config.reset()
    for _, dir in ipairs(created_dirs) do
      vim.fn.delete(dir, 'rf')
    end
    created_dirs = {}
  end)
end

local function stub_system(captured)
  return function(cmd, opts, on_exit)
    captured.cmd = cmd
    captured.opts = opts
    captured.on_exit = on_exit
  end
end

local function stub_ok_executable()
  cli._set_executable(function()
    return 1
  end)
end

describe('git/ref branches / tags 引数組み立て', function()
  restore_after_each()

  it('branches は for-each-ref refs/heads/ を %(refname:short) で実行する', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()

    ref.branches({}, function() end)

    assert.same({
      'git',
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads/',
    }, captured.cmd)
    assert.is_true(captured.opts.text)
  end)

  it('tags は refs/tags/ を列挙する', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()

    ref.tags({}, function() end)

    assert.same({
      'git',
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/tags/',
    }, captured.cmd)
  end)

  it(
    'branches は stdout 行を名前配列へ変換して data に持つ ok 結果を返す',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.branches({ cwd = '/tmp/x' }, function(res)
        received = res
      end)
      assert.equals('/tmp/x', captured.opts.cwd)
      captured.on_exit { code = 0, stdout = 'feature\nmain\n', stderr = '' }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = { 'feature', 'main' },
      }, received)
    end
  )

  it('tag が 0 個 (stdout 空) では data が空配列の ok 結果になる', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()

    local received
    ref.tags({}, function(res)
      received = res
    end)
    captured.on_exit { code = 0, stdout = '', stderr = '' }

    assert.same({ __class = 'review.Result', ok = true, data = {} }, received)
  end)

  it('git 失敗 (repo 外など) は code=E_REF の err 結果に化する', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()

    local received
    ref.branches({}, function(res)
      received = res
    end)
    captured.on_exit { code = 128, stdout = '', stderr = 'fatal: not a git repository\n' }

    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 128 },
      error = 'fatal: not a git repository',
      code = 'E_REF',
    }, received)
  end)
end)

describe('git/ref rev_parse', function()
  restore_after_each()

  it(
    'rev-parse --verify <ref> を実行し、stdout の sha を末尾改行なしで data に返す',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.rev_parse({ ref = 'main' }, function(res)
        received = res
      end)
      assert.same({ 'git', 'rev-parse', '--verify', 'main' }, captured.cmd)
      captured.on_exit {
        code = 0,
        stdout = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4\n',
        stderr = '',
      }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4',
      }, received)
    end
  )

  it('解決不能 ref (exit 128) は code=E_REF の err 結果を返す', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()

    local received
    ref.rev_parse({ ref = 'nope' }, function(res)
      received = res
    end)
    captured.on_exit {
      code = 128,
      stdout = '',
      stderr = "fatal: ambiguous argument 'nope': unknown revision\n",
    }

    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 128 },
      error = "fatal: ambiguous argument 'nope': unknown revision",
      code = 'E_REF',
    }, received)
  end)
end)

describe('git/ref top_level (repo top 解決)', function()
  restore_after_each()

  it(
    'rev-parse --show-toplevel を実行し、stdout を末尾改行除去で data に返す',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.top_level({ cwd = '/tmp/sub' }, function(res)
        received = res
      end)
      assert.same({ 'git', 'rev-parse', '--show-toplevel' }, captured.cmd)
      captured.on_exit { code = 0, stdout = '/tmp/repo\n', stderr = '' }

      assert.same({ __class = 'review.Result', ok = true, data = '/tmp/repo' }, received)
    end
  )

  it('repo 外 (exit 128) は code=E_REF の err 結果を返す', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()

    local received
    ref.top_level({}, function(res)
      received = res
    end)
    captured.on_exit {
      code = 128,
      stdout = '',
      stderr = 'fatal: not a git repository\n',
    }

    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 128 },
      error = 'fatal: not a git repository',
      code = 'E_REF',
    }, received)
  end)
end)

describe('git/ref 実 git', function()
  restore_after_each()

  -- ブランチ 2・tag 1 の実 repo を作り、列挙と解決を本物で通す
  -- (スタブにしか通っていない経路を残さない)。
  local function build_repo()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    table.insert(created_dirs, dir)
    local function git(args)
      local out =
        vim.system(vim.list_extend({ 'git' }, args), { cwd = dir, text = true }):wait(10000)
      if out.code ~= 0 then
        error('git ' .. table.concat(args, ' ') .. ' 失敗: ' .. out.stderr, 0)
      end
      return out.stdout
    end
    git { 'init', '-q', '-b', 'main' }
    git { 'config', 'user.email', 'spec@example.com' }
    git { 'config', 'user.name', 'spec' }
    local f = io.open(vim.fs.joinpath(dir, 'a.txt'), 'w')
    f:write 'a\n'
    f:close()
    git { 'add', '-A' }
    git { 'commit', '-qm', 'base' }
    git { 'branch', 'feature' }
    git { 'tag', 'v1.0.0' }
    return dir, git
  end

  local function await_result(call)
    local received
    call(function(res)
      received = res
    end)
    vim.wait(6000, function()
      return received ~= nil
    end)
    return received
  end

  it('branches は実 repo の全 branch を for-each-ref 順 (feature, main) で返す', function()
    local dir = build_repo()

    local received = await_result(function(cb)
      ref.branches({ cwd = dir }, cb)
    end)

    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { 'feature', 'main' },
    }, received)
  end)

  it(
    'top_level は実 repo の sub ディレクトリ cwd から top-level 絶対パスを返す',
    function()
      local dir = build_repo()
      local sub = vim.fs.joinpath(dir, 'sub')
      vim.fn.mkdir(sub, 'p')

      local received = await_result(function(cb)
        ref.top_level({ cwd = sub }, cb)
      end)

      -- macOS の /var -> /private/var 系 symlink を実パスに寄せて比較する。
      local expected = vim
        .system({ 'git', 'rev-parse', '--show-toplevel' }, { cwd = dir, text = true })
        :wait(10000).stdout
        :gsub('%s+$', '')
      assert.same({ __class = 'review.Result', ok = true, data = expected }, received)
    end
  )

  it('tags と rev_parse が実 git で名前一緒・sha 解決できる', function()
    local dir, git = build_repo()

    local tags = await_result(function(cb)
      ref.tags({ cwd = dir }, cb)
    end)
    assert.same({ __class = 'review.Result', ok = true, data = { 'v1.0.0' } }, tags)

    local sha = await_result(function(cb)
      ref.rev_parse({ ref = 'main', cwd = dir }, cb)
    end)
    local expected = git({ 'rev-parse', '--verify', 'main' }):gsub('%s+$', '')
    assert.same({ __class = 'review.Result', ok = true, data = expected }, sha)

    local bad = await_result(function(cb)
      ref.rev_parse({ ref = 'no-such-ref', cwd = dir }, cb)
    end)
    assert.same(false, bad.ok)
    assert.equals('E_REF', bad.code)
  end)
end)
