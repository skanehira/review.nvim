-- git/repo: `git switch` 実行アダプタ (diff-review「開始」head 解決フロー)。
-- switch はユーザーのチェックアウトを動かす操作で、[y/N] 確認を通過したときだけ
-- handler が呼ぶ (INV-3。成否の判定責任は handler、ここは実行と結果型変換のみ)。
-- テスト方針 (diff-review.md「単体 (git リポジトリ実 FS)」) どおり成功/失敗は
-- temp repo の実 FS で検証する (成功 = ディスクの内容と branch が実際に変わる、
-- 失敗 = チェックアウトが無傷)。exec 注入は _set_executable 不在経路
-- (bin 実行不能) だけに通す。
local repo = require 'review.git.repo'
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

-- main (x.txt=main-content) / feature (x.txt=feature-content) の実 repo。
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
  local f = io.open(vim.fs.joinpath(dir, 'x.txt'), 'w')
  f:write 'main-content\n'
  f:close()
  git { 'add', '-A' }
  git { 'commit', '-qm', 'base' }
  git { 'checkout', '-qb', 'feature' }
  local f2 = io.open(vim.fs.joinpath(dir, 'x.txt'), 'w')
  f2:write 'feature-content\n'
  f2:close()
  git { 'add', '-A' }
  git { 'commit', '-qm', 'feat' }
  git { 'checkout', '-q', 'main' }
  return dir, git
end

local function read_x(dir)
  local f = io.open(vim.fs.joinpath(dir, 'x.txt'), 'r')
  if f == nil then
    return nil
  end
  local text = f:read '*a'
  f:close()
  return text
end

describe('git/repo switch (実 FS)', function()
  restore_after_each()

  it(
    '実在ブランチへの switch は ok で、ディスク内容と HEAD が実際に feature へ動く',
    function()
      local dir = build_repo()

      local res = await_result(function(cb)
        repo.switch({ ref = 'feature', cwd = dir }, cb)
      end)

      assert.equals(true, res.ok)
      assert.equals('feature-content\n', read_x(dir))
      local head = vim
        .system({ 'git', '-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD' }, { text = true })
        :wait(10000)
      assert.equals('feature\n', head.stdout)
    end
  )

  it(
    '存在しない ref への switch は err (E_GIT・fatal 主行) でチェックアウトは無傷',
    function()
      local dir = build_repo()

      local res = await_result(function(cb)
        repo.switch({ ref = 'no-such-branch', cwd = dir }, cb)
      end)

      assert.equals(false, res.ok)
      assert.equals('E_GIT', res.code)
      assert.is_true(res.error:find('no-such-branch', 1, true) ~= nil, res.error)
      assert.equals('main-content\n', read_x(dir))
    end
  )
end)

describe('git/repo switch 実行不能 (bin 不在)', function()
  restore_after_each()

  it('git が実行不能なら spawn せず同期 err (E_GIT) を cb へ返す', function()
    local spawned = false
    cli._set_system(function()
      spawned = true
    end)
    cli._set_executable(function()
      return 0
    end)

    local res = await_result(function(cb)
      repo.switch({ ref = 'feature', cwd = '/tmp' }, cb)
    end)

    assert.equals(false, res.ok)
    assert.equals('E_GIT', res.code)
    assert.equals('git not found', res.error)
    assert.is_false(spawned)
  end)
end)
