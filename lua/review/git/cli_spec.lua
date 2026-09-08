local cli = require 'review.git.cli'
local result = require 'review.core.result'

-- vim.system / vim.fn.executable の注入スタブを組み、結果型への変換を検証する。
-- 実行アダプタの境界なので DI スタブが testing.md 優先順位① (DI + fake) に該当する。
-- real git を呼ぶ integration テストを最後に 1 件置き、スタブにしか通っていない経路をなくす。

-- plenary busted は describe 外の before_each/after_each を持たないため、
-- 注入の解除は各 describe 先で this helper を呼び registered after_each にする。
local function restore_injections_after_each()
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
  end)
end

-- 注入用の疑似 system: 呼ばれたら (cmd, opts, on_exit) を捕捉し、
-- テストが明示的に on_exit を呼ぶまでコールバックを発火しない。
local function stub_system(captured)
  return function(cmd, opts, on_exit)
    captured.cmd = cmd
    captured.opts = opts
    captured.on_exit = on_exit
    captured.calls = (captured.calls or 0) + 1
  end
end

describe('cli.run 成功', function()
  restore_injections_after_each()
  it('exit code 0 の stdout を ok 結果型へ変換して cb に返す', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    cli._set_executable(function()
      return 1
    end)

    local received
    cli.run('git', { 'diff', 'main', 'feature' }, nil, function(res)
      received = res
    end)

    captured.on_exit { code = 0, stdout = 'diff --git a/x b/x\n', stderr = '' }
    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { stdout = 'diff --git a/x b/x\n', code = 0 },
    }, received)
    assert.same({ 'git', 'diff', 'main', 'feature' }, captured.cmd)
    assert.is_true(captured.opts.text)
  end)

  it('呼び出し側 opts は vim.system へ透過される (cwd など)', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    cli._set_executable(function()
      return 1
    end)

    cli.run('git', { 'status' }, { cwd = '/tmp/repo' }, function() end)
    assert.equals('/tmp/repo', captured.opts.cwd)
    assert.is_true(captured.opts.text)
  end)
end)

describe('cli.run 失敗', function()
  restore_injections_after_each()
  it('非ゼロ終了では stderr 末尾 1 行が error になり code=E_GIT', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    cli._set_executable(function()
      return 1
    end)

    local received
    cli.run('git', { 'diff', 'bad-ref' }, nil, function(res)
      received = res
    end)
    captured.on_exit {
      code = 128,
      stdout = '',
      stderr = "warning: line one\nfatal: bad revision 'bad-ref'\n",
    }

    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 128 },
      error = "fatal: bad revision 'bad-ref'",
      code = 'E_GIT',
    }, received)
  end)

  it(
    'stderr が空の非ゼロ終了では終了コード入りの日本語メッセージになる',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      cli._set_executable(function()
        return 1
      end)

      local received
      cli.run('git', { 'diff' }, nil, function(res)
        received = res
      end)
      captured.on_exit { code = 1, stdout = '', stderr = '' }

      assert.same({
        __class = 'review.Result',
        ok = false,
        data = { stdout = '', code = 1 },
        error = 'git が終了コード 1 で失敗しました',
        code = 'E_GIT',
      }, received)
    end
  )

  it('err_code=E_GH を渡すとエラー code は E_GH になる', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    cli._set_executable(function()
      return 1
    end)

    local received
    cli.run('gh', { 'pr', 'view', '1' }, { err_code = result.codes.E_GH }, function(res)
      received = res
    end)
    captured.on_exit { code = 1, stdout = '', stderr = 'could not resolve pull request number 1\n' }

    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 1 },
      error = 'could not resolve pull request number 1',
      code = 'E_GH',
    }, received)
    assert.same({ 'gh', 'pr', 'view', '1' }, captured.cmd)
  end)

  it('spawn 自体の失敗 (out.err) は起動失敗メッセージの err になる', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    cli._set_executable(function()
      return 1
    end)

    local received
    cli.run('git', { 'diff' }, nil, function(res)
      received = res
    end)
    captured.on_exit { err = 'ENOENT: no such file or directory' }

    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 0 },
      error = 'git の起動に失敗しました',
      code = 'E_GIT',
    }, received)
  end)

  it(
    'system 呼び出しが同期的に error を投げても結果型 err に変換する',
    function()
      -- 横断規約: 手続きは例外を投げず結果型を返す。Neovim の実装により
      -- vim.system は spawn 失敗を投げる (cwd 不正等) ためアダプタで吸収する。
      cli._set_system(function()
        error('ENOENT: no such file or directory (cwd)', 0)
      end)
      cli._set_executable(function()
        return 1
      end)

      local received
      cli.run('git', { 'log' }, {}, function(res)
        received = res
      end)

      assert.same({
        __class = 'review.Result',
        ok = false,
        error = 'git の起動に失敗しました',
        code = 'E_GIT',
      }, received)
    end
  )

  it(
    'bin が実行不能なら system を呼ばず「見つかりません」を同期的に cb へ返す',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      cli._set_executable(function()
        return 0
      end)

      local received
      cli.run('git', { 'diff' }, nil, function(res)
        received = res
      end)

      assert.same({
        __class = 'review.Result',
        ok = false,
        error = 'git が見つかりません',
        code = 'E_GIT',
      }, received)
      assert.equals(nil, captured.calls)
    end
  )
end)

describe('cli.run 非同期ディスパッチ', function()
  restore_injections_after_each()
  it('fast event 内の on_exit でも cb はスローイベントで呼ばれる', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    cli._set_executable(function()
      return 1
    end)

    local called_in_fast_event
    cli.run('git', { 'diff' }, nil, function(res)
      called_in_fast_event = vim.in_fast_event()
      captured.result = res
    end)

    -- libuv async のコールバックは fast event。そこから on_exit を発火して
    -- 「cb を直接呼ばず vim.schedule で回す」ことを検証する。
    local async
    async = vim.uv.new_async(function()
      captured.on_exit { code = 0, stdout = 'scheduled-out\n', stderr = '' }
      async:close()
    end)
    async:send()
    vim.wait(2000, function()
      return captured.result ~= nil
    end)

    -- 実装が fast event 内で cb を直接呼べば true になり、この検証は失敗する。
    assert.equals(false, called_in_fast_event)
    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { stdout = 'scheduled-out\n', code = 0 },
    }, captured.result)
  end)
end)

describe('cli.run real vim.system', function()
  restore_injections_after_each()
  -- ⓪ 本物を使う経路: 注入しないことで system 実体とディスパッチの両方を検証する。
  it('本当の git --version が ok 結果型で返る', function()
    local received
    cli.run('git', { '--version' }, nil, function(res)
      received = res
    end)

    vim.wait(5000, function()
      return received ~= nil
    end)
    assert.is_true(received ~= nil)
    assert.equals(0, received.data.code)
    assert.is_true(received.ok)
    -- バージョン文字列は環境依存なので形状だけ正アサーションする。
    assert.is_true(received.data.stdout:match '^git version ' ~= nil)
  end)

  it(
    'git リポジトリ以外での git log は E_GIT 失敗として stderr 末尾を返す',
    function()
      -- tmpdir 契約: mktemp -d で作り、最後に掃除する (DESIGN.md「開発・検証コマンド」)。
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local received
      cli.run('git', { 'log' }, { cwd = dir }, function(res)
        received = res
      end)

      vim.wait(5000, function()
        return received ~= nil
      end)
      vim.fn.delete(dir, 'rf')
      assert.is_true(received ~= nil)
      assert.equals(false, received.ok)
      assert.equals('E_GIT', received.code)
      assert.equals(128, received.data.code)
      -- メッセージ末尾行は git/ロケール依存のため、行になっていることだけ検証する
      -- (末尾 1 行抽出はスタブ側テストで完全一致検証済み)。
      assert.is_true(received.error:find '\n' == nil)
      assert.is_true(#received.error > 0)
    end
  )
end)
