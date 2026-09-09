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

-- ブランチ 2・tag 1 の実 repo 作成 (実 git 系 describe 共通のヘルパー)。
local function build_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  table.insert(created_dirs, dir)
  local function git(args)
    local out = vim.system(vim.list_extend({ 'git' }, args), { cwd = dir, text = true }):wait(10000)
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

describe('git/ref fetch_pull / delete_ref / remotes (pr-worktree fork 経路)', function()
  restore_after_each()

  it(
    'fetch_pull は `git fetch <remote> refs/pull/<n>/head:review-nvim/pr-<n>` を実行し data に ref 名を返す',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.fetch_pull({ remote = 'origin', number = 7, cwd = '/repo' }, function(res)
        received = res
      end)
      assert.same({
        'git',
        'fetch',
        'origin',
        'refs/pull/7/head:review-nvim/pr-7',
      }, captured.cmd)
      assert.equals('/repo', captured.opts.cwd)
      captured.on_exit { code = 0, stdout = '', stderr = '' }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = 'review-nvim/pr-7',
      }, received)
    end
  )

  it(
    'fetch 失敗 (ref 不在 / 非 ff) は code=E_REF の err に stderr 末尾 1 行で返す',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.fetch_pull({ remote = 'origin', number = 7 }, function(res)
        received = res
      end)
      captured.on_exit {
        code = 128,
        stdout = '',
        stderr = "fatal: couldn't find remote ref refs/pull/7/head\n",
      }

      assert.same({
        __class = 'review.Result',
        ok = false,
        data = { stdout = '', code = 128 },
        error = "fatal: couldn't find remote ref refs/pull/7/head",
        code = 'E_REF',
      }, received)
    end
  )

  it(
    'delete_ref は `git update-ref -d <full-ref>` を実行する (:Review delete の自前 ref 掃除)',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.delete_ref({ ref = 'refs/heads/review-nvim/pr-7', cwd = '/repo' }, function(res)
        received = res
      end)
      assert.same({ 'git', 'update-ref', '-d', 'refs/heads/review-nvim/pr-7' }, captured.cmd)
      captured.on_exit { code = 0, stdout = '', stderr = '' }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = { stdout = '', code = 0 },
      }, received)
    end
  )

  it(
    'pr_ref_storage は fetch が実保存する refs/heads/ 下のフルネームを返す (update-ref -d は短縮名を拒否するため掃除はこの形が要る)',
    function()
      assert.equals('refs/heads/review-nvim/pr-7', ref.pr_ref_storage(7))
    end
  )

  it(
    'remotes は `git remote` の行を名前配列へ変換する (fork fetch の remote 選択入力)',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.remotes({ cwd = '/repo' }, function(res)
        received = res
      end)
      assert.same({ 'git', 'remote' }, captured.cmd)
      captured.on_exit { code = 0, stdout = 'fork\norigin\n', stderr = '' }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = { 'fork', 'origin' },
      }, received)
    end
  )

  it(
    'remotes が空 (stdout 空) は data が空配列の ok (0 リモート判定を err にしない)',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      ref.remotes({}, function(res)
        received = res
      end)
      captured.on_exit { code = 0, stdout = '', stderr = '' }

      assert.same({ __class = 'review.Result', ok = true, data = {} }, received)
    end
  )

  it(
    'fetch 保存相当の refs/heads/review-nvim/pr-7 を短縮名で解決し、フルネーム delete で消せる (実 git)',
    function()
      local dir, git = build_repo()
      local short = 'review-nvim/pr-7'
      local full = ref.pr_ref_storage(7)
      assert.equals('refs/heads/' .. short, full)
      local sha = git({ 'rev-parse', '--verify', 'main' }):gsub('%s+$', '')

      local created = vim
        .system({ 'git', 'update-ref', full, sha }, { cwd = dir, text = true })
        :wait(10000)
      assert.equals(0, created.code)

      local resolved = await_result(function(cb)
        ref.rev_parse({ ref = short, cwd = dir }, cb)
      end)
      assert.same({ __class = 'review.Result', ok = true, data = sha }, resolved)

      local deleted = await_result(function(cb)
        ref.delete_ref({ ref = full, cwd = dir }, cb)
      end)
      assert.equals(true, deleted.ok)

      local missing = await_result(function(cb)
        ref.rev_parse({ ref = short, cwd = dir }, cb)
      end)
      assert.equals(false, missing.ok)
      assert.equals('E_REF', missing.code)
    end
  )

  it(
    'fetch_pull は実 git で refs/pull/<n>/head を fetch し短縮 ref を返す (origin に擬似 pull ref を置く)',
    function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(dir, 'origin'), 'p')
      vim.fn.mkdir(vim.fs.joinpath(dir, 'work'), 'p')
      table.insert(created_dirs, dir)

      local init_r = vim.system(
        { 'git', 'init', '-q', '--bare', '-b', 'main', 'origin' },
        { cwd = dir, text = true }
      )
      init_r:wait(10000)
      vim.system({ 'git', 'clone', '-q', 'origin', 'work' }, { cwd = dir, text = true }):wait(10000)
      local work = vim.fs.joinpath(dir, 'work')
      local git = function(args)
        local out =
          vim.system(vim.list_extend({ 'git' }, args), { cwd = work, text = true }):wait(10000)
        assert.equals(0, out.code, out.stderr)
        return out.stdout
      end
      git { 'config', 'user.email', 'spec@example.com' }
      git { 'config', 'user.name', 'spec' }
      local f = io.open(vim.fs.joinpath(work, 'a.txt'), 'w')
      f:write 'a\n'
      f:close()
      git { 'add', '-A' }
      git { 'commit', '-qm', 'base' }
      git { 'push', '-q', 'origin', 'main' }
      -- PR の head 相当: topic ブランチを pull ref として origin に置く
      git { 'checkout', '-qb', 'topic' }
      local f2 = io.open(vim.fs.joinpath(work, 'a.txt'), 'w')
      f2:write 'topic\n'
      f2:close()
      git { 'commit', '-qam', 'topic' }
      git { 'push', '-q', 'origin', 'topic:refs/pull/7/head' }

      local received = await_result(function(cb)
        ref.fetch_pull({ remote = 'origin', number = 7, cwd = work }, cb)
      end)
      assert.same({ __class = 'review.Result', ok = true, data = 'review-nvim/pr-7' }, received)

      local head_content = await_result(function(cb)
        ref.rev_parse({ ref = 'review-nvim/pr-7', cwd = work }, cb)
      end)
      local topic_sha = git({ 'rev-parse', '--verify', 'topic' }):gsub('%s+$', '')
      assert.same({ __class = 'review.Result', ok = true, data = topic_sha }, head_content)
    end
  )
end)

describe('git/ref 実 git', function()
  restore_after_each()

  -- ブランチ 2・tag 1 の実 repo を作り、列挙と解決を本物で通す
  -- (スタブにしか通っていない経路を残さない)。build_repo / await_result は
  -- ファイル共通ヘルパー (fork 経路の describe と共有)。

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
