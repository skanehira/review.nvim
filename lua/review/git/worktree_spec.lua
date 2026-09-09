-- git/worktree: worktree add / remove / prune / status / list の引数組み立てと
-- 結果型 (pr-worktree.md「worktree 作成判断」「実装の配置」。DESIGN.md「既知の制約」
-- worktree 一時 ref / --force / crash 掃除の各行)。
-- 注入 system スタブで引数検証、add/list/remove は実 git 1 ケースで Round-trip。
local worktree = require 'review.git.worktree'
local cli = require 'review.git.cli'
local config = require 'review.config'

local state = { dirs = {} }

local function restore_after_each()
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    config.reset()
    for _, dir in ipairs(state.dirs) do
      vim.fn.delete(dir, 'rf')
    end
    state.dirs = {}
  end)
end

local function stub_system()
  state.calls = {}
  cli._set_system(function(cmd, opts, on_exit)
    table.insert(state.calls, { cmd = cmd, opts = opts, on_exit = on_exit })
  end)
  cli._set_executable(function()
    return 1
  end)
end

local function last()
  return state.calls[#state.calls]
end

local function await_result(call)
  local received
  call(function(res)
    received = res
  end)
  vim.wait(8000, function()
    return received ~= nil
  end, 10)
  return received
end

describe('git/worktree add / remove / prune 引数組み立て', function()
  restore_after_each()

  it(
    'add は `git worktree add --detach <path> <ref>` を repo cwd で実行する (--detach で branch 競合回避)',
    function()
      stub_system()
      worktree.add({ repo = '/repo', path = '/wt/x', ref = 'feature' }, function() end)

      assert.same({ 'git', 'worktree', 'add', '--detach', '/wt/x', 'feature' }, last().cmd)
      assert.equals('/repo', last().opts.cwd)
    end
  )

  it(
    'remove は `git worktree remove <path>`、force 指定なら remove の直後へ --force を挿入する',
    function()
      stub_system()
      worktree.remove({ repo = '/repo', path = '/wt/x' }, function() end)
      assert.same({ 'git', 'worktree', 'remove', '/wt/x' }, last().cmd)

      worktree.remove({ repo = '/repo', path = '/wt/x', force = true }, function() end)
      assert.same({ 'git', 'worktree', 'remove', '--force', '/wt/x' }, last().cmd)
    end
  )

  it('prune は `git worktree prune` を repo cwd で実行する', function()
    stub_system()
    worktree.prune({ repo = '/repo' }, function() end)
    assert.same({ 'git', 'worktree', 'prune' }, last().cmd)
    assert.equals('/repo', last().opts.cwd)
  end)

  it(
    '失敗 (終了コード非 0) は stderr 末尾 1 行 + code=E_WORKTREE の err 結果を返す',
    function()
      stub_system()
      local received
      worktree.add({ repo = '/repo', path = '/wt/x', ref = 'feature' }, function(res)
        received = res
      end)
      last().on_exit {
        code = 255,
        stdout = '',
        stderr = 'fatal: /wt/x is already registered\n',
      }

      assert.same({
        __class = 'review.Result',
        ok = false,
        data = { stdout = '', code = 255 },
        error = 'fatal: /wt/x is already registered',
        code = 'E_WORKTREE',
      }, received)
    end
  )

  it('成功は data に { stdout, code } を持つ ok 結果を返す', function()
    stub_system()
    local received
    worktree.prune({ repo = '/repo' }, function(res)
      received = res
    end)
    last().on_exit { code = 0, stdout = '', stderr = '' }

    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { stdout = '', code = 0 },
    }, received)
  end)
end)

describe('git/worktree status / list', function()
  restore_after_each()

  it(
    'status は `git -C <path> status --porcelain` を実行し、出力から dirty 判定を返す',
    function()
      stub_system()
      local received
      worktree.status({ repo = '/repo', path = '/wt/x' }, function(res)
        received = res
      end)
      assert.same({ 'git', '-C', '/wt/x', 'status', '--porcelain' }, last().cmd)
      last().on_exit { code = 0, stdout = ' M a.lua\n?? b.lua\n', stderr = '' }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = { dirty = true, porcelain = { ' M a.lua', '?? b.lua' } },
      }, received)
    end
  )

  it('status 出力が空なら dirty=false (未コミット変更なし)', function()
    stub_system()
    local received
    worktree.status({ repo = '/repo', path = '/wt/x' }, function(res)
      received = res
    end)
    last().on_exit { code = 0, stdout = '', stderr = '' }

    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { dirty = false, porcelain = {} },
    }, received)
  end)

  it(
    'status は dir 消滅などの git 失敗を code=E_WORKTREE の err で返す (close の検知不能を黙って clean にしない)',
    function()
      stub_system()
      local received
      worktree.status({ repo = '/repo', path = '/gone' }, function(res)
        received = res
      end)
      last().on_exit {
        code = 128,
        stdout = '',
        stderr = "fatal: cannot change to '/gone': No such file or directory\n",
      }

      assert.equals('E_WORKTREE', received.code)
      assert.equals(false, received.ok)
    end
  )

  it(
    'list は `git worktree list --porcelain` の worktree 行を絶対パス配列へ変換する',
    function()
      stub_system()
      local received
      worktree.list({ repo = '/repo' }, function(res)
        received = res
      end)
      assert.same({ 'git', 'worktree', 'list', '--porcelain' }, last().cmd)
      last().on_exit {
        code = 0,
        stdout = table.concat({
          'worktree /repo',
          'HEAD abc123',
          'branch refs/heads/main',
          '',
          'worktree /wt/x',
          'HEAD abc123',
          'detached',
          '',
        }, '\n'),
        stderr = '',
      }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = { '/repo', '/wt/x' },
      }, received)
    end
  )

  it('list の worktree 行が 0 件でも data は空配列の ok (欠損にしない)', function()
    stub_system()
    local received
    worktree.list({ repo = '/repo' }, function(res)
      received = res
    end)
    last().on_exit { code = 0, stdout = '', stderr = '' }

    assert.same({ __class = 'review.Result', ok = true, data = {} }, received)
  end)
end)

describe('git/worktree remove_dir (掃除用の自前作 dir 再帰削除)', function()
  restore_after_each()

  it(
    'ネストした dir 配下のファイルを再帰削除する (close/delete/scan の残骸掃除共用)',
    function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, 'd/e'), 'p')
      table.insert(state.dirs, root)
      local f = io.open(vim.fs.joinpath(root, 'd/e/f.txt'), 'w')
      f:write 'x\n'
      f:close()

      assert.equals(true, worktree.remove_dir(root))
      assert.is_true(vim.uv.fs_stat(root) == nil)
    end
  )

  it(
    '既に存在しない path は remove_dir が ok (掃除の冪等性 / 目標状態充足)',
    function()
      local gone = vim.fs.joinpath(vim.fn.tempname(), 'not-made')
      -- 存在しないことは fs_stat 前段で確認済み (tempname は作らない)
      assert.is_true(vim.uv.fs_stat(gone) == nil)
      assert.equals(true, worktree.remove_dir(gone))
    end
  )
end)

describe('git/worktree 実 git round-trip', function()
  restore_after_each()

  local function build_repo()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    table.insert(state.dirs, dir)
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
    return dir, git
  end

  it(
    -- 決定表と既知の制約の各行 (remove 失敗・--force・prune) を実 git で通す
    'add -> list 登録 -> status clean -> 編集で dirty -> remove 失敗 -> force remove で消える',
    function()
      local dir = build_repo()
      local wt = vim.fs.joinpath(vim.fn.tempname(), 'wt')
      table.insert(state.dirs, vim.fs.dirname(wt))

      local added = await_result(function(cb)
        worktree.add({ repo = dir, path = wt, ref = 'HEAD' }, cb)
      end)
      assert.equals(true, added.ok)

      local listed = await_result(function(cb)
        worktree.list({ repo = dir }, cb)
      end)
      assert.equals(true, listed.ok)
      local found = false
      for _, p in ipairs(listed.data) do
        if vim.uv.fs_realpath(p) == vim.uv.fs_realpath(wt) then
          found = true
        end
      end
      assert.equals(true, found)

      local clean = await_result(function(cb)
        worktree.status({ repo = dir, path = wt }, cb)
      end)
      assert.same(
        { __class = 'review.Result', ok = true, data = { dirty = false, porcelain = {} } },
        clean
      )

      local f = io.open(vim.fs.joinpath(wt, 'a.txt'), 'a')
      f:write 'dirty\n'
      f:close()
      local dirty = await_result(function(cb)
        worktree.status({ repo = dir, path = wt }, cb)
      end)
      assert.equals(true, dirty.ok)
      assert.equals(true, dirty.data.dirty)

      -- 既知の制約: 未コミット変更があると remove は失敗する (--force 確認の根拠)
      local plain = await_result(function(cb)
        worktree.remove({ repo = dir, path = wt }, cb)
      end)
      assert.equals(false, plain.ok)
      assert.equals('E_WORKTREE', plain.code)

      local forced = await_result(function(cb)
        worktree.remove({ repo = dir, path = wt, force = true }, cb)
      end)
      assert.equals(true, forced.ok)
      assert.is_true(vim.uv.fs_stat(wt) == nil)

      local after = await_result(function(cb)
        worktree.prune({ repo = dir }, cb)
      end)
      assert.equals(true, after.ok)
    end
  )

  it(
    '同一 path への 2 回目 add は E_WORKTREE で失敗する (衝突 = prune 回収対象)',
    function()
      local dir = build_repo()
      local wt = vim.fs.joinpath(vim.fn.tempname(), 'wt')
      table.insert(state.dirs, vim.fs.dirname(wt))

      local first = await_result(function(cb)
        worktree.add({ repo = dir, path = wt, ref = 'HEAD' }, cb)
      end)
      assert.equals(true, first.ok)

      local dup = await_result(function(cb)
        worktree.add({ repo = dir, path = wt, ref = 'HEAD' }, cb)
      end)
      assert.equals(false, dup.ok)
      assert.equals('E_WORKTREE', dup.code)

      vim.fn.delete(wt, 'rf')
      local pruned = await_result(function(cb)
        worktree.prune({ repo = dir }, cb)
      end)
      assert.equals(true, pruned.ok)

      local readded = await_result(function(cb)
        worktree.add({ repo = dir, path = wt, ref = 'HEAD' }, cb)
      end)
      assert.equals(true, readded.ok)
    end
  )
end)
