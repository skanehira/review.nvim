-- handlers/health: 起動 scan の worktree 残骸掃除 (pr-worktree.md「異常終了からの回復」、
-- persistence-restore.md「起動時」3)。open セッションの実在確認 (消滅は記録回収 =
-- 復元時の作成判断で再生成) と、closed + created_by_us=true 残骸 dir の通知付き掃除。
-- INV-3: created_by_us=true の記録がある自前作成分だけを対象にする。
-- store / paths は注入 tmpdir + 実ファイル、git (prune/list) は注入スタブ。
local health = require 'review.handlers.health'
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local store = require 'review.store.session'

local REPO_TOP = vim.fn.tempname()
vim.fn.mkdir(REPO_TOP, 'p')

local REAL_NOTIFY = vim.notify
local REAL_INPUT = vim.ui.input

local state = {}

-- worktree path -> 登録有無 (list スタブの回答) を決める。
-- mode: 'registered' | 'unregistered'
local function stub_git(opts_after_each)
  state.calls = {}
  cli._set_executable(function()
    return 1
  end)
  cli._set_system(function(cmd, _o, on_exit)
    table.insert(state.calls, cmd)
    if cmd[2] == 'worktree' and cmd[3] == 'list' then
      local out = 'worktree ' .. REPO_TOP .. '\n'
      for _, w in ipairs(state.registered) do
        out = out .. 'worktree ' .. w .. '\n'
      end
      on_exit { code = 0, stdout = out .. '\n', stderr = '' }
      return
    end
    if cmd[2] == 'worktree' and cmd[3] == 'prune' then
      on_exit { code = 0, stdout = '', stderr = '' }
      return
    end
    error('health スタブ外の git 実行: ' .. table.concat(cmd, ' '), 0)
  end)
  if opts_after_each == nil then
    after_each(function()
      cli._set_system(nil)
      cli._set_executable(nil)
      config.reset()
      paths._set_data_dir(nil)
      store._set_now(nil)
      store._set_notify(nil)
      vim.notify = REAL_NOTIFY
      vim.ui.input = REAL_INPUT
      vim.fn.delete(state.dir, 'rf')
    end)
  end
end

local function use_env()
  before_each(function()
    config.reset()
    state = {
      notifications = {},
      registered = {},
      dir = vim.fn.tempname(),
      calls = {},
    }
    vim.fn.mkdir(state.dir, 'p')
    paths._set_data_dir(state.dir)
    store._set_now(function()
      return 4321
    end)
    store._set_notify(function() end)
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    vim.ui.input = function(_opts, cb)
      cb 'n'
    end
  end)
  stub_git(true)
end

-- worktree 付きセッションの保存 (record = nil / {path, created_by_us})
local function save_session(overrides)
  local sess = {
    version = 1,
    id = 'pr-7',
    repo = REPO_TOP,
    mode = 'pr',
    base = 'main',
    head = 'review-nvim/pr-7',
    pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
    worktree = vim.NIL,
    status = 'closed',
    files = {},
    comments = {},
    created_at = 1,
  }
  for k, v in pairs(overrides or {}) do
    sess[k] = v
  end
  assert.equals(true, store.save(sess).ok)
  return sess
end

local function mkdir_dir()
  local dir = vim.fs.joinpath(state.dir, 'wt')
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function loaded(id)
  return store.load(REPO_TOP, id or 'pr-7').data
end

describe('health.sweep open セッションの実在確認 (異常終了回復)', function()
  use_env()

  it(
    'open + dir 実在 + git 登録済み -> 何もしない (crash 後でも worktree は復元で再利用される)',
    function()
      local dir = mkdir_dir()
      state.registered = { dir }
      local sess = save_session {
        status = 'open',
        worktree = { path = dir, created_by_us = true },
      }
      local mtime_before = vim.uv.fs_stat(paths.session_file(REPO_TOP, 'pr-7')).mtime

      local done = false
      health.sweep(REPO_TOP, function()
        done = true
      end)
      assert.equals(true, done)

      assert.equals(0, #state.notifications)
      assert.is_true(vim.uv.fs_stat(dir) ~= nil) -- dir 保持
      -- list 参照のみ (prune なし・save なし = mtime 不変)
      assert.same({ 'git', 'worktree', 'list', '--porcelain' }, state.calls[1])
      assert.equals(1, #state.calls)
      assert.same(sess.worktree, loaded().worktree)
      assert.same(mtime_before, vim.uv.fs_stat(paths.session_file(REPO_TOP, 'pr-7')).mtime)
    end
  )

  it(
    'open + dir 消滅 -> 記録から worktree を外して save + INFO 通知 (復元時の作成判断で再生成)',
    function()
      local dir = mkdir_dir()
      vim.fn.delete(dir, 'rf')
      save_session { status = 'open', worktree = { path = dir, created_by_us = true } }

      health.sweep(REPO_TOP, function() end)

      assert.same({
        msg = 'review.nvim: pr-7 の worktree ディレクトリが消滅しています。'
          .. '記録から worktree を外しました (復元時に作成判断で再生成します)',
        level = vim.log.levels.INFO,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.equals(vim.NIL, loaded().worktree)
      assert.equals(4321, loaded().updated_at)
      -- dir がないので git 起動は不要 (0 コール)
      assert.equals(0, #state.calls)
    end
  )

  it(
    'INV-3: open + created_by_us=false の dir は触れない (同 scan の作成分孤児は掃除される)',
    function()
      local user_dir = mkdir_dir()
      save_session {
        id = 'user-dir',
        status = 'open',
        worktree = { path = user_dir, created_by_us = false },
      }
      local our_dir = vim.fs.joinpath(state.dir, 'ours')
      vim.fn.mkdir(our_dir, 'p')
      save_session {
        id = 'pr-7',
        status = 'open',
        worktree = { path = our_dir, created_by_us = true },
      }
      state.registered = {}

      health.sweep(REPO_TOP, function() end)

      -- 走査は動いた: pr-7 (自前分・未登録) が掃除され通知が出た
      assert.equals(1, #state.notifications)
      assert.equals(
        ('review.nvim: worktree 残骸を掃除しました pr-7: %s (git 未登録)'):format(
          our_dir
        ),
        state.notifications[1].msg
      )
      assert.is_true(vim.uv.fs_stat(our_dir) == nil)
      -- INV-3: 非自前 dir は無傷 (created_by_us が走査の唯一の削除許可)
      assert.is_true(vim.uv.fs_stat(user_dir) ~= nil)
      assert.equals(false, loaded('user-dir').worktree.created_by_us)
    end
  )

  it(
    'open + dir 実在 + git 未登録 (作成分の孤児) -> WARN 通知 + dir 削除 + prune + 記録回収',
    function()
      local dir = mkdir_dir()
      state.registered = {} -- list に載らない
      save_session { status = 'open', worktree = { path = dir, created_by_us = true } }

      health.sweep(REPO_TOP, function() end)

      assert.same({
        msg = ('review.nvim: worktree 残骸を掃除しました pr-7: %s (git 未登録)'):format(
          dir
        ),
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.is_true(vim.uv.fs_stat(dir) == nil)
      assert.equals(vim.NIL, loaded().worktree)
      -- open + dir 実在は「再利用可否」の登録確認 (list) が先、掃除 prune が後
      assert.same({ 'git', 'worktree', 'list', '--porcelain' }, state.calls[1])
      assert.same({ 'git', 'worktree', 'prune' }, state.calls[2])
    end
  )
end)

describe('health.sweep closed + created_by_us 残骸', function()
  use_env()

  it(
    'closed + dir 残骸 -> 「掃除してよい残骸」通知 (WARN) + 削除 + prune + worktree=null 化',
    function()
      local dir = mkdir_dir()
      save_session { status = 'closed', worktree = { path = dir, created_by_us = true } }

      health.sweep(REPO_TOP, function() end)

      assert.same({
        msg = ('review.nvim: worktree 残骸を掃除しました pr-7: %s (close 掃除の失敗残骸)'):format(
          dir
        ),
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.is_true(vim.uv.fs_stat(dir) == nil)
      -- closed の掃除は save しない (:Review delete と競合して掃除後の save が
      -- 削除済み JSON を復活させ得るため — E2E phase6 で検出した実バグ)。
      -- dir 消滅後の記録は classify==skip なので放置で無害。
      assert.same({ path = dir, created_by_us = true }, loaded().worktree)
      assert.same({ 'git', 'worktree', 'prune' }, state.calls[1])
    end
  )

  it(
    'INV-3: closed でも created_by_us=false の dir は掃除しない (同 scan の作成分残骸は掃除される)',
    function()
      local user_dir = mkdir_dir()
      save_session {
        id = 'user-dir',
        status = 'closed',
        worktree = { path = user_dir, created_by_us = false },
      }
      local our_dir = vim.fs.joinpath(state.dir, 'ours')
      vim.fn.mkdir(our_dir, 'p')
      save_session { status = 'closed', worktree = { path = our_dir, created_by_us = true } }

      health.sweep(REPO_TOP, function() end)

      assert.equals(1, #state.notifications)
      assert.equals(
        ('review.nvim: worktree 残骸を掃除しました pr-7: %s (close 掃除の失敗残骸)'):format(
          our_dir
        ),
        state.notifications[1].msg
      )
      assert.is_true(vim.uv.fs_stat(our_dir) == nil)
      assert.is_true(vim.uv.fs_stat(user_dir) ~= nil)
      assert.equals(false, loaded('user-dir').worktree.created_by_us)
    end
  )

  it(
    'worktree 記録なしセッションだけ (正常 close 後) -> git 起動 0・無通知 (scan が誤検出しない対照)',
    function()
      save_session { status = 'closed' }
      save_session { id = 'main--feature', mode = 'branch', worktree = vim.NIL, status = 'open' }

      health.sweep(REPO_TOP, function() end)

      assert.equals(0, #state.notifications)
      assert.equals(0, #state.calls)
      assert.equals(2, #store.list(REPO_TOP).data)
      assert.equals(4321, loaded('main--feature').updated_at)
    end
  )

  it(
    'prune 失敗 (WARN) も scan 全体を壊さず、dir 削除と次のセッションの掃除は続く',
    function()
      local dir = mkdir_dir()
      save_session {
        id = 'pr-1',
        status = 'closed',
        pr = { number = 1, url = 'u' },
        head = 'review-nvim/pr-1',
        worktree = { path = dir, created_by_us = true },
      }
      local dir2 = vim.fs.joinpath(state.dir, 'wt2')
      vim.fn.mkdir(dir2, 'p')
      save_session {
        id = 'pr-2',
        status = 'closed',
        pr = { number = 2, url = 'u' },
        head = 'review-nvim/pr-2',
        worktree = { path = dir2, created_by_us = true },
      }
      local prune_seen = 0
      cli._set_system(function(cmd, _o, on_exit)
        table.insert(state.calls, cmd)
        if cmd[2] == 'worktree' and cmd[3] == 'prune' then
          prune_seen = prune_seen + 1
          if prune_seen == 1 then
            on_exit { code = 128, stdout = '', stderr = 'fatal: prune boom\n' }
            return
          end
          on_exit { code = 0, stdout = '', stderr = '' }
          return
        end
        error('health スタブ外の git 実行: ' .. table.concat(cmd, ' '), 0)
      end)

      health.sweep(REPO_TOP, function() end)

      -- pr-1: 掃除 WARN -> prune 失敗 WARN、pr-2: 掃除 WARN (順序は slug 昇順)
      assert.equals(3, #state.notifications)
      assert.equals(
        ('review.nvim: worktree 残骸を掃除しました pr-1: %s (close 掃除の失敗残骸)'):format(
          dir
        ),
        state.notifications[1].msg
      )
      assert.equals(
        'review.nvim: worktree prune に失敗しました (pr-1): fatal: prune boom',
        state.notifications[2].msg
      )
      assert.equals(
        ('review.nvim: worktree 残骸を掃除しました pr-2: %s (close 掃除の失敗残骸)'):format(
          dir2
        ),
        state.notifications[3].msg
      )
      assert.is_true(vim.uv.fs_stat(dir) == nil)
      assert.is_true(vim.uv.fs_stat(dir2) == nil)
      -- closed は掃除しても save しない (E2E phase6 の競合バグ検出に対する決定)。
      -- dir 消滅後の記録は classify==skip で、以後 scan に再登場しない。
      assert.same({ path = dir, created_by_us = true }, loaded('pr-1').worktree)
      assert.same({ path = dir2, created_by_us = true }, loaded('pr-2').worktree)
    end
  )
end)
