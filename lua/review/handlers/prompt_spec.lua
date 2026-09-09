-- handlers/prompt: `:Review prompt` / y の出力経路 (docs/design/features/ai-prompt.md
-- 「出力経路」「実装の配置」「エッジケースの決定」)。検証の中心は
--   (1) "0 / + / * レジスタへのコピーと provider 無し退路 (WARN)
--   (2) active 不在 E_NOT_ACTIVE・0 件 / 全件 outdated の INFO 拒否・除外件数 INFO
--   (3) y の見出しなし本文と outdated 既定除外
-- セッションは git スタブで実開始する (comments_spec と同じ土俵。UI 実バッファ経由で
-- カーソル行 -> new 側行 -> コメント検索の実経路を通す)。
local cli = require 'review.git.cli'
local comments_handler = require 'review.handlers.comments'
local config = require 'review.config'
local paths = require 'review.store.paths'
local prompt_handler = require 'review.handlers.prompt'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'

local REPO_TOP = '/spec/repo-top'
local SLUG = 'main--feature'
local DIFF_A_NAME = 'review://diff/' .. SLUG .. '/a.lua'

local SENTINEL = 'SENTINEL-MUST-NOT-BE-CLOBBERED'

local RAW_DIFF = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1,3 +1,5 @@',
  ' one',
  '+two',
  '+three',
  ' four',
  '-five',
  ' six',
  '',
}, '\n')

local REAL_NOTIFY = vim.notify

local state = {}

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {} }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    paths._set_data_dir(state.dir)
    store._set_now(function()
      return 4321
    end)
    store._set_notify(function() end)
    session_handler._set_now(function()
      return 4321
    end)
    comments_handler._set_now(function()
      return 4321
    end)
    session_handler._reset()
    cli._set_system(function(cmd, _opts, on_exit)
      if cmd[2] == 'rev-parse' then
        on_exit { code = 0, stdout = REPO_TOP .. '\n', stderr = '' }
      else
        on_exit { code = 0, stdout = RAW_DIFF, stderr = '' }
      end
    end)
    cli._set_executable(function()
      return 1
    end)
    state.real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    -- 外部状態の分離: レジスタと provider 定義を退避し sentinel で初期化する
    -- (after_each で復元。provider 無し経路と有り経路の両方を決定的に検証するため)。
    -- provider 定義は has_provider の検出元 3 系統すべてを消す。g:clipboard だけ
    -- 消しても clipboard#copy や package.loaded.clipboard が残留すると、
    -- 「無し経路」前提のテストが実際には有り経路を通ってしまう。
    state.saved = {
      r0 = vim.fn.getreg '0',
      rplus = vim.fn.getreg '+',
      rstar = vim.fn.getreg '*',
      gclipboard = vim.g.clipboard,
    }
    vim.g.clipboard = vim.NIL
    vim.cmd 'silent! delfunction clipboard#copy'
    package.preload.clipboard = nil
    package.loaded.clipboard = nil
    -- clipboard#copy 検出系統のテスト用定義元ファイル。autoload 名の関数は
    -- :function では名前不一致で E746 になるため、autoload/clipboard.vim を
    -- source する形で定義する (実機 probe で exists()==1 を確認済み)。
    vim.fn.mkdir(state.dir .. '/autoload', 'p')
    state.clipboard_autoload = state.dir .. '/autoload/clipboard.vim'
    vim.fn.writefile({ 'function clipboard#copy()', 'endfunction' }, state.clipboard_autoload)
    vim.fn.setreg('0', SENTINEL)
    vim.fn.setreg('+', SENTINEL)
    vim.fn.setreg('*', SENTINEL)
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    session_handler.start { base = 'main', head = 'feature' }
    state.session = session_handler.active()
    -- worktree 無しブランチセッション (作成判断 skip = head==HEAD かつ porcelain 空) の
    -- shape に揃える。この fixture の git stub は status --porcelain にも RAW_DIFF を
    -- 返すため作成判断が「必要」に転び、自前 worktree 記録が入ってパス規則が絶対 path
    -- 分岐へ化ける (#6 の worktree 作成判断入り込み後のあおり)。
    -- この spec 群の意図は整形・コピー経路・provider 検出 (ai-prompt.md「パスの規則」の
    -- repo 相対分岐) で、絶対 path 分岐は ctx マッピング describe と core/prompt_spec
    -- が pin 済み。相対 @path の検証経路を壊さないため worktree を明示的に空にする。
    state.session.worktree = vim.NIL
    state.diff_buf = vim.fn.bufnr(DIFF_A_NAME)
    state.diff_win = vim.fn.win_findbuf(state.diff_buf)[1]
    vim.api.nvim_set_current_win(state.diff_win)
    -- row3=' one'(new1) row4='+two'(2) row5='+three'(3) row6=' four'(4)
    -- row7='-five'(del) row8=' six'(5)
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
    vim.fn.setreg('0', state.saved.r0)
    vim.fn.setreg('+', state.saved.rplus)
    vim.fn.setreg('*', state.saved.rstar)
    -- 復元: nil 代入はできないため未定義だった値は vim.NIL に戻す
    -- (検出側は userdata を「provider 無し」として扱う)。
    vim.g.clipboard = state.saved.gclipboard == nil and vim.NIL or state.saved.gclipboard
    vim.cmd 'silent! delfunction clipboard#copy'
    package.preload.clipboard = nil
    package.loaded.clipboard = nil
    paths._set_data_dir(nil)
    store._set_now(nil)
    store._set_notify(nil)
    session_handler._set_now(nil)
    comments_handler._set_now(nil)
    session_handler._reset()
    config.reset()
    cli._set_system(nil)
    cli._set_executable(nil)
    vim.fn.delete(state.dir, 'rf')
  end)
end

-- session.comments にテスト用コメントを置く (core/comment の生成物と同形)。
local function seed(comments)
  for _, c in ipairs(comments) do
    table.insert(state.session.comments, c)
  end
end

local function comment(id, file, line, end_line, body, state_name)
  return {
    id = id,
    file = file,
    line = line,
    end_line = end_line or line,
    body = body,
    anchor = vim.NIL,
    state = state_name or 'active',
    created_at = 4321,
  }
end

local function full_prompt(block_lines)
  local lines = {
    'Review the changes in main..feature. Please address the comments below.',
    '',
  }
  for _, line in ipairs(block_lines) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, '\n')
end

describe('handlers.prompt E_NOT_ACTIVE / provider 無し退路', function()
  use_env()

  it(
    'active 無しでは E_NOT_ACTIVE を同期で返し WARN、レジスタは触れない',
    function()
      session_handler._reset()

      local res = prompt_handler.all()

      assert.same({
        __class = 'review.Result',
        ok = false,
        error = 'review.nvim: レビュー進行中セッションがありません',
        code = 'E_NOT_ACTIVE',
      }, res)
      assert.same({
        msg = 'review.nvim: レビュー進行中セッションがありません',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.equals(SENTINEL, vim.fn.getreg '0')
      assert.equals(SENTINEL, vim.fn.getreg '+')
    end
  )

  -- has_provider の検出元 3 系統 (:help clipboard-provider の定義経路 2 つ +
  -- 将来ビルド向け clipboard.provider()) と全条件不成立の対照を、同一構造
  -- (provider を配置 -> all() -> 期待を assert) のパラメータとして 1 本に揃える。
  -- 検出元を 1 つでも has_provider から消すと、その系統のケースが「無し経路」に
  -- 落ち、+/* が SENTINEL のまま / WARN が出て失敗する (系統ごとの pin)。
  local provider_cases = {
    {
      name = 'g:clipboard table',
      arrange = function()
        vim.g.clipboard = {
          type = 'command',
          copy = { ['+'] = 'cat', ['*'] = 'cat' },
          paste = { ['+'] = 'cat', ['*'] = 'cat' },
        }
      end,
    },
    {
      -- autoload clipboard#copy (vim-clipboard 系のレガシー provider はこの経路)。
      name = 'autoload clipboard#copy',
      arrange = function()
        vim.cmd('source ' .. state.clipboard_autoload)
      end,
    },
    {
      name = "require('clipboard').provider()",
      arrange = function()
        package.preload.clipboard = function()
          return {
            provider = function()
              return { name = 'review-spec-stub' }
            end,
          }
        end
      end,
    },
    {
      -- 対照: 検出元を 1 つでも残すとこのケースが有り経路に化ける (= 前 cases の
      -- arrange の取りこぼしを検出する)。E2E もこの退路でコピー成功を検証する。
      name = '全条件不成立',
      arrange = function() end,
      no_provider = true,
    },
  }
  it(
    'provider 検出元 (g:clipboard / clipboard#copy / provider()) なら +/* 書写成功、無しは "0 のみ + WARN',
    function()
      local expected = full_prompt { '@a.lua#L2-L3', 'use map' }
      for _, case in ipairs(provider_cases) do
        -- ケース間の分離: 前ケースの provider 配置と +/* / "0 を持越ししない
        -- (before_each の無 provider 状態と同じ起点に戻す)。
        vim.g.clipboard = vim.NIL
        vim.cmd 'silent! delfunction clipboard#copy'
        package.preload.clipboard = nil
        package.loaded.clipboard = nil
        vim.fn.setreg('0', SENTINEL)
        vim.fn.setreg('+', SENTINEL)
        vim.fn.setreg('*', SENTINEL)
        state.session.comments = {}
        seed { comment('c1', 'a.lua', 2, 3, 'use map') }
        case.arrange()
        state.notifications = {}

        local res = prompt_handler.all()

        -- provider の有無は結果契約 (text / count / "0 コピー) を変えない
        assert.same(
          { __class = 'review.Result', ok = true, data = { text = expected, count = 1 } },
          res,
          case.name .. ': 結果契約'
        )
        assert.equals(expected, vim.fn.getreg '0', case.name .. ': "0 にコピー')
        if case.no_provider then
          -- 無し経路: +/* を触っていない (書き込み試行の残骸がゼロ) + WARN 1 件
          assert.equals(SENTINEL, vim.fn.getreg '+', case.name .. ': + を触らない')
          assert.equals(SENTINEL, vim.fn.getreg '*', case.name .. ': * を触らない')
          assert.same({
            msg = 'review.nvim: クリップボード provider がありません。"0 レジスタにのみコピーしました',
            level = vim.log.levels.WARN,
          }, state.notifications[1], case.name .. ': WARN')
          assert.equals(1, #state.notifications, case.name .. ': 通知は WARN のみ')
        else
          -- 有り経路: +/* に書けて、通知はゼロ (見た目の成功ではなく読み戻しで判定)
          assert.equals(expected, vim.fn.getreg '+', case.name .. ': +/* に書写成功')
          assert.equals(expected, vim.fn.getreg '*', case.name .. ': +/* に書写成功')
          assert.equals(0, #state.notifications, case.name .. ': WARN を出さない')
        end
      end
    end
  )

  it(
    'copy=false では一切コピーせず text を返す (Lua API テストフック)',
    function()
      seed { comment('c1', 'a.lua', 2, 3, 'use map') }
      state.notifications = {}

      local res = prompt_handler.all { copy = false }

      local expected = full_prompt { '@a.lua#L2-L3', 'use map' }
      assert.same(
        { __class = 'review.Result', ok = true, data = { text = expected, count = 1 } },
        res
      )
      assert.equals(SENTINEL, vim.fn.getreg '0')
      assert.equals(0, #state.notifications)
    end
  )
end)

describe('handlers.prompt 0 件 / outdated の情報経路', function()
  use_env()

  it(
    'コメント 0 件では INFO「コメントがありません」でコピーしない',
    function()
      local res = prompt_handler.all()

      assert.same({
        msg = 'review.nvim: コメントがありません',
        level = vim.log.levels.INFO,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.same({ __class = 'review.Result', ok = true, data = { text = '', count = 0 } }, res)
      assert.equals(SENTINEL, vim.fn.getreg '0')
    end
  )

  it(
    '全件 outdated では「有効なコメントがありません」で終了しコピーしない',
    function()
      seed { comment('c1', 'a.lua', 2, nil, 'stale', 'outdated') }

      local res = prompt_handler.all()

      assert.same({
        msg = 'review.nvim: 有効なコメントがありません',
        level = vim.log.levels.INFO,
      }, state.notifications[1])
      assert.same({ __class = 'review.Result', ok = true, data = { text = '', count = 0 } }, res)
      assert.equals(SENTINEL, vim.fn.getreg '0')
    end
  )

  it('outdated 混在では active のみで構築し除外件数を INFO する', function()
    seed {
      comment('c1', 'a.lua', 2, nil, 'keep'),
      comment('c2', 'a.lua', 3, nil, 'stale', 'outdated'),
    }

    local res = prompt_handler.all { copy = false }

    assert.same({
      msg = 'review.nvim: 1 件を除外しました (outdated)',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { text = full_prompt { '@a.lua#L2', 'keep' }, count = 1 },
    }, res)
  end)
end)

describe('handlers.prompt for_file (スコープ解決)', function()
  use_env()

  it(
    'diff に無いパスは INFO「そのファイルはレビュー対象の diff にありません」',
    function()
      seed { comment('c1', 'a.lua', 2, 3, 'use map') }

      local res = prompt_handler.for_file 'nope.lua'

      assert.same({
        msg = 'review.nvim: そのファイルはレビュー対象の diff にありません',
        level = vim.log.levels.INFO,
      }, state.notifications[1])
      assert.same({ __class = 'review.Result', ok = true, data = { text = '', count = 0 } }, res)
      assert.equals(SENTINEL, vim.fn.getreg '0')
    end
  )

  it('file 指定ではそのファイルのコメントのみ + 見出しは同じ', function()
    seed {
      comment('c1', 'a.lua', 2, nil, 'in a'),
      comment('c2', 'b.lua', 9, 11, 'in b'),
    }
    state.session.files['b.lua'] = { viewed = true }

    local res = prompt_handler.for_file('b.lua', { copy = false })

    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { text = full_prompt { '@b.lua#L9-L11', 'in b' }, count = 1 },
    }, res)
  end)
end)

describe('handlers.prompt ctx マッピング (worktree / PR セッション)', function()
  use_env()

  it(
    'worktree/PR を持つセッションでは絶対 path と PR 見出しのプロンプトになる',
    function()
      state.session.mode = 'pr'
      state.session.pr = { number = 42, url = 'https://github.com/o/r/pull/42' }
      state.session.worktree = { path = '/xdg/wt/pr-42', created_by_us = true }
      seed { comment('c1', 'a.lua', 2, 3, 'use map') }

      local res = prompt_handler.all { copy = false }

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = {
          text = table.concat({
            'Review PR #42 (https://github.com/o/r/pull/42) — main..feature. '
              .. 'Please address the comments below.',
            '',
            '@/xdg/wt/pr-42/a.lua#L2-L3',
            'use map',
          }, '\n'),
          count = 1,
        },
      }, res)
    end
  )
end)

describe('y キー (カーソル行 range のコメントを yank)', function()
  use_env()

  local function focus_row(row)
    vim.api.nvim_win_set_cursor(state.diff_win, { row, 0 })
  end

  it('y: 見出しなしで @path#L.. と本文を "0 に入れる', function()
    seed { comment('c1', 'a.lua', 2, 3, 'use map') }
    focus_row(5) -- '+three' = new 3 (range の内側)

    comments_handler.yank_current()

    assert.equals('@a.lua#L2-L3\nuse map', vim.fn.getreg '0')
    -- provider 無し退路の WARN のみ (コピー成功を止まらない)
    assert.same({
      msg = 'review.nvim: クリップボード provider がありません。"0 レジスタにのみコピーしました',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
  end)

  it('y: カーソル行のコメントが全件 outdated ならコピーせず INFO', function()
    seed { comment('c1', 'a.lua', 2, 3, 'stale', 'outdated') }
    focus_row(4)

    comments_handler.yank_current()

    assert.same({
      msg = 'review.nvim: outdated のためプロンプトに含めませんでした',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals(SENTINEL, vim.fn.getreg '0')
  end)

  it('y: 混在時は active のみコピーし除外件数を INFO する', function()
    seed {
      comment('c1', 'a.lua', 2, 3, 'multi'),
      comment('c2', 'a.lua', 2, 2, 'stale', 'outdated'),
    }
    focus_row(4)

    comments_handler.yank_current()

    assert.same({
      msg = 'review.nvim: 1 件を除外しました (outdated)',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals('@a.lua#L2-L3\nmulti', vim.fn.getreg '0')
  end)

  it('y: コメントが無い行では既存の WARN で "0 を触れない', function()
    focus_row(8) -- ' six' = new 5、コメント無し

    comments_handler.yank_current()

    assert.same({
      msg = 'review.nvim: その行のコメントはありません',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(SENTINEL, vim.fn.getreg '0')
  end)
end)
