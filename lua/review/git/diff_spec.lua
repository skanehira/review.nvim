-- git/diff: `git diff <base> <head>` の実行アダプタ (diff-review.md「開始」手順 2)。
-- 引数組み立て (-U<n> 込み) と結果型分岐は注入 system スタブで検証し、
-- 実 git 経路を 1 ケース置いてスタブにしか通っていない経路を残さない
-- (git/cli_spec.lua と同じ規律)。
local diff_adapter = require 'review.git.diff'
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

-- 呼ばれたら (cmd, opts, on_exit) を捕捉し、明示的に on_exit を呼ぶまで発火しない。
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

-- tail.txt -U0 の生出力を git 2.55 実測のまま使う (core/diff_spec とは別に、
-- アダプタが parse を通すことの検証用フィクスチャ)。
local RAW_DIFF = table.concat({
  'diff --git a/tail2.txt b/tail2.txt',
  'index 795ea43..ba21892 100644',
  '--- a/tail2.txt',
  '+++ b/tail2.txt',
  '@@ -1,0 +2 @@ t1',
  '+t2',
  '',
}, '\n')

local PARSED_TAIL2 = {
  path = 'tail2.txt',
  status = 'M',
  binary = false,
  added = 1,
  deleted = 0,
  hunks = {
    {
      old_start = 1,
      old_count = 0,
      new_start = 2,
      new_count = 1,
      header = '@@ -1,0 +2 @@ t1',
      lines = { { kind = 'add', text = 't2', new_line = 2 } },
    },
  },
}

describe('git/diff fetch 引数組み立て', function()
  restore_after_each()

  it(
    'diff_context 未指定では git diff <base> <head> のみ、cwd は vim.system へ渡る',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      diff_adapter.fetch(
        { base = 'main', head = 'feature', cwd = '/tmp/review-spec-repo' },
        function() end
      )

      assert.same({ 'git', 'diff', 'main', 'feature' }, captured.cmd)
      assert.equals('/tmp/review-spec-repo', captured.opts.cwd)
      assert.is_true(captured.opts.text)
    end
  )

  it('config.diff_context=5 では引数に -U5 が挿入される', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()
    config.setup { diff_context = 5 }

    diff_adapter.fetch({ base = 'a', head = 'b' }, function() end)

    assert.same({ 'git', 'diff', '-U5', 'a', 'b' }, captured.cmd)
  end)

  it('設定した git_bin が実行 bin に使われる', function()
    local captured = {}
    cli._set_system(stub_system(captured))
    stub_ok_executable()
    config.setup { git_bin = 'mygit' }

    diff_adapter.fetch({ base = 'main', head = 'feature' }, function() end)

    assert.same({ 'mygit', 'diff', 'main', 'feature' }, captured.cmd)
  end)
end)

describe('git/diff fetch 結果型分岐', function()
  restore_after_each()

  it(
    '成功時は生出力 text と core/diff パース済み files を data に持つ ok 結果を返す',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      diff_adapter.fetch({ base = 'main', head = 'feature' }, function(res)
        received = res
      end)
      captured.on_exit { code = 0, stdout = RAW_DIFF, stderr = '' }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = { text = RAW_DIFF, files = { PARSED_TAIL2 } },
      }, received)
    end
  )

  it(
    'ref 解決不能 (exit 128) は code=E_REF・stderr 末尾行を error とする err 結果',
    function()
      local captured = {}
      cli._set_system(stub_system(captured))
      stub_ok_executable()

      local received
      diff_adapter.fetch({ base = 'nope', head = 'feature' }, function(res)
        received = res
      end)
      captured.on_exit {
        code = 128,
        stdout = '',
        stderr = "fatal: ambiguous argument 'nope': unknown revision or path\n",
      }

      assert.same({
        __class = 'review.Result',
        ok = false,
        data = { stdout = '', code = 128 },
        error = "fatal: ambiguous argument 'nope': unknown revision or path",
        code = 'E_REF',
      }, received)
    end
  )
end)

describe('git/diff fetch 実 git', function()
  restore_after_each()

  it(
    '実リポジトリの main..headbr 差分が parse 済みで ok 結果として返る',
    function()
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
      local f = io.open(vim.fs.joinpath(dir, 'x.txt'), 'w')
      f:write 'one\n'
      f:close()
      git { 'add', '-A' }
      git { 'commit', '-qm', 'base' }
      git { 'checkout', '-qb', 'headbr' }
      local f2 = io.open(vim.fs.joinpath(dir, 'x.txt'), 'w')
      f2:write 'one\ntwo\n'
      f2:close()
      git { 'add', '-A' }
      git { 'commit', '-qm', 'two' }

      local received = nil
      diff_adapter.fetch({ base = 'main', head = 'headbr', cwd = dir }, function(res)
        received = res
      end)
      vim.wait(6000, function()
        return received ~= nil
      end)

      assert.is_true(received ~= nil and received.ok)
      assert.same({
        path = 'x.txt',
        status = 'M',
        binary = false,
        added = 1,
        deleted = 0,
        hunks = {
          {
            old_start = 1,
            old_count = 1,
            new_start = 1,
            new_count = 2,
            header = '@@ -1 +1,2 @@',
            lines = {
              { kind = 'context', text = 'one', new_line = 1 },
              { kind = 'add', text = 'two', new_line = 2 },
            },
          },
        },
      }, received.data.files[1])
      assert.equals(1, #received.data.files)
    end
  )
end)
