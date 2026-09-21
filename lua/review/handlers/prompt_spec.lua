-- handlers/prompt: `:Review prompt` / y の出力経路 (docs/design/features/ai-prompt.md
-- 「出力経路」「実装の配置」「エッジケースの決定」)。検証の中心は
--   (1) "0 / + / * レジスタへのコピーと provider 無し退路 (WARN)
--   (2) active 不在 E_NOT_ACTIVE・0 件 / 全件 outdated の INFO 拒否・除外件数 INFO
--   (3) y の見出しなし本文と outdated 既定除外
-- セッションは git スタブで実開始する (comments_spec と同じ土俵。head 実ファイル窓の
-- 恒等行 (buffer 行 = new 側行) からカーソル行 -> コメント検索の実経路を通す)。
local cli = require 'review.git.cli'
local comments_handler = require 'review.handlers.comments'
local config = require 'review.config'
local paths = require 'review.store.paths'
local prompt_handler = require 'review.handlers.prompt'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'

local SENTINEL = 'SENTINEL-MUST-NOT-BE-CLOBBERED'

-- head (作業ツリー) の a.lua = new 側 5 行。head 実ファイル窓は :edit 相当の
-- 実在ファイル経路なのでディスク実在が前提 (恒等行の源)。
local HEAD_TEXT = table.concat({ 'one', 'two', 'three', 'four', 'six' }, '\n') .. '\n'

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
local REAL_INPUT = vim.ui.input

local state = {}

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {} }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    state.repo = vim.fs.joinpath(state.dir, 'repo')
    vim.fn.mkdir(state.repo, 'p')
    state.repo = vim.uv.fs_realpath(state.repo) or state.repo
    local f = io.open(vim.fs.joinpath(state.repo, 'a.lua'), 'w')
    f:write(HEAD_TEXT)
    f:close()
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
        on_exit { code = 0, stdout = state.repo .. '\n', stderr = '' }
      elseif cmd[2] == 'show' then
        -- base scratch 充填 (git show main:a.lua)
        on_exit { code = 0, stdout = 'one\nfive deleted\nsix\n', stderr = '' }
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
    -- 3 窓 UI と review:// buf はプロセス共有 (comments_spec / session_spec と同型)。
    if ui_windows.state() ~= nil then
      ui_windows.close()
    end
    ui_windows.reset()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    -- 外部状態の分離: レジスタと provider 定義を退避し sentinel で初期化する
    -- (after_each で復元。provider 無し経路と有り経路の両方を決定的に検証するため)。
    -- provider 定義は has_provider の検出元 4 系統すべてを消す。g:clipboard だけ
    -- 消しても clipboard#copy / provider#clipboard#Call / package.loaded.clipboard
    -- が残留すると、「無し経路」前提のテストが実際には有り経路を通ってしまう
    -- (macOS の既定 pbcopy provider は provider#clipboard#Call として見える)。
    state.saved = {
      r0 = vim.fn.getreg '0',
      rplus = vim.fn.getreg '+',
      rstar = vim.fn.getreg '*',
      gclipboard = vim.g.clipboard,
    }
    vim.g.clipboard = vim.NIL
    vim.cmd 'silent! delfunction clipboard#copy'
    vim.cmd 'silent! delfunction provider#clipboard#Call'
    -- g:loaded_clipboard_provider=2 のまま関数を消すと nvim core が register 操作で
    -- «=2 but provider#clipboard#Call is not defined» を投げる (実測)。0 = provider
    -- 無しの状態へ落としてから register を触る。
    vim.g.loaded_clipboard_provider = 0
    package.preload.clipboard = nil
    package.loaded.clipboard = nil
    -- clipboard#copy / provider#clipboard#Call 検出系統のテスト用定義元ファイル。
    -- autoload 名の関数は :function では名前不一致で E746 になるため、autoload/
    -- 配下を source する形で定義する (実機 probe で exists()==1 を確認済み)。
    vim.fn.mkdir(state.dir .. '/autoload/provider', 'p')
    state.clipboard_autoload = state.dir .. '/autoload/clipboard.vim'
    vim.fn.writefile({ 'function clipboard#copy()', 'endfunction' }, state.clipboard_autoload)
    state.provider_autoload = state.dir .. '/autoload/provider/clipboard.vim'
    vim.fn.writefile(
      { 'function! provider#clipboard#Call(...)', 'endfunction' },
      state.provider_autoload
    )
    -- 実書込 round-trip probe もテストでは決定的にする (macOS の実 clipboard は
    -- 動くため、probe 実機のままだと「無し経路」テストが環境依存になる)。
    prompt_handler._set_clipboard_probe(function()
      return false
    end)
    vim.fn.setreg('0', SENTINEL)
    vim.fn.setreg('+', SENTINEL)
    vim.fn.setreg('*', SENTINEL)
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    session_handler.start { base = 'main', head = 'feature' }
    state.session = session_handler.active()
    -- head==HEAD 一致の通常経路 (作成判断は mode=pr のみで branch は worktree なし)。
    -- head 実ファイル窓 (専有 tab 開通後 focus == head 窓)。恒等行: buffer 行 N =
    -- new 側行 N (1 one / 2 two / 3 three / 4 four / 5 six)。
    state.head_buf = vim.fn.bufnr(vim.fs.joinpath(state.repo, 'a.lua'))
    state.head_win = ui_windows.win 'head'
    vim.api.nvim_set_current_win(state.head_win)
  end)
  after_each(function()
    -- close はコメントあり確認として vim.ui.input を引く (headless の既定 provider は
    -- 無限待ちになるため 'y' 応答に戻してから閉じる)。
    vim.ui.input = function(_, cb)
      cb 'y'
    end
    session_handler.close()
    vim.ui.input = REAL_INPUT
    if ui_windows.state() ~= nil then
      ui_windows.close()
    end
    ui_windows.reset()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      pcall(vim.cmd, 'tabclose!')
    end
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        pcall(vim.cmd, 'tabclose!')
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.notify = REAL_NOTIFY
    -- provider#clipboard#Call を先に元へ戻してから register を復元する
    -- (関数が無いまま +/* を触ると nvim core が例外を投げ、復元が中断する — 実測)。
    -- 実 runtime の autoload を再 source する (対応コマンドがある環境では登録済み、
    -- 無ければ未定義のまま = 元の状態。g:loaded_clipboard_provider も再設定される)。
    vim.cmd 'silent! delfunction provider#clipboard#Call'
    vim.cmd 'unlet! g:loaded_clipboard_provider'
    pcall(vim.cmd, 'runtime autoload/provider/clipboard.vim')
    vim.fn.setreg('0', state.saved.r0)
    vim.fn.setreg('+', state.saved.rplus)
    vim.fn.setreg('*', state.saved.rstar)
    -- 復元: nil 代入はできないため未定義だった値は vim.NIL に戻す
    -- (検出側は userdata を「provider 無し」として扱う)。
    vim.g.clipboard = state.saved.gclipboard == nil and vim.NIL or state.saved.gclipboard
    vim.cmd 'silent! delfunction clipboard#copy'
    package.preload.clipboard = nil
    package.loaded.clipboard = nil
    prompt_handler._set_clipboard_probe(nil)
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
      -- '+/*' は provider 無し環境で初期 setreg ごと保持されない (CI stable/0.10 実測、
      -- 内部選択保持はビルド/版依存の挙動)。観測できる "0 だけ「触っていない」ことを pin する。
      assert.equals(SENTINEL, vim.fn.getreg '0')
    end
  )

  -- has_provider の検出元 4 系統 (:help clipboard-provider の定義経路 +
  -- Neovim 標準 provider#clipboard#Call + 将来ビルド向け clipboard.provider()) と
  -- 全条件不成立の対照を、同一構造
  -- (provider を配置 -> all() -> 期待を assert) のパラメータとして 1 本に揃える。
  -- 検出元を 1 つでも has_provider から消すと、その系統が「無し経路」に落ち
  -- (有り経路側は notifications[1] が WARN になりコピー INFO の assert が落ち、無し
  -- 側は provider が誤検出されて WARN が消える) 失敗する。+/* 内容の sentinel は
  -- 無し環境で初期 setreg が保持されないため検証に使わない (CI stable/0.10 実測)。
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
      -- Neovim 標準 provider autoload。runtime の autoload/provider/clipboard.vim が
      -- 対応コマンド (pbcopy / xclip / wl-copy 等) がある環境でのみ関数を登録する
      -- (実測: macOS=1 / tools 無し headless=0)。旧実装はこの系統が無く macOS の
      -- 既定 provider を誤って「無し」と判定していた (ユーザー報告の clipboard バグ)。
      name = 'provider#clipboard#Call (Neovim 標準)',
      arrange = function()
        vim.cmd 'silent! delfunction provider#clipboard#Call'
        vim.cmd('source ' .. state.provider_autoload)
        vim.g.loaded_clipboard_provider = 2 -- 実機 (対応コマンドあり環境) と同じ状態
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
    'provider 検出元 4 系統 (g:clipboard / clipboard#copy / provider#clipboard#Call /'
      .. ' provider()) なら +/* 書写成功、無しは "0 のみ + WARN',
    function()
      local expected = full_prompt { '@a.lua#L2-L3', 'use map' }
      for _, case in ipairs(provider_cases) do
        -- ケース間の分離: 前ケースの provider 配置と +/* / "0 を持越ししない
        -- (before_each の無 provider 状態と同じ起点に戻す)。
        vim.g.clipboard = vim.NIL
        vim.cmd 'silent! delfunction clipboard#copy'
        vim.cmd 'silent! delfunction provider#clipboard#Call'
        vim.g.loaded_clipboard_provider = 0
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
          -- 無し経路: WARN 1 件 + "0 のみ (provider 無しでは +/* の内容はビルド/版依存で
          -- 検証対象にできないため、arrange 漏れの検出は「WARN が必ず出る」側に置く —
          -- provider が有りと誤検出されれば WARN 0 件になりこの assert が落ちる)。
          assert.equals(expected, vim.fn.getreg '0', case.name .. ': "0 にコピー')
          assert.same({
            msg = 'review.nvim: クリップボード provider がありません。"0 レジスタにのみコピーしました',
            level = vim.log.levels.WARN,
          }, state.notifications[1], case.name .. ': WARN')
          assert.equals(1, #state.notifications, case.name .. ': 通知は WARN のみ')
        else
          -- 有り経路: 無し経路に落ちていないこと = 通知がコピー成功 INFO 1 件
          -- (arrange した provider が has_provider で検出され、「無し」に誤判定なら
          -- notifications[1] が WARN になりこの assert が落ちる)。コピー完了の
          -- 可視化 (2026-09 ユーザー依頼: 無音成功が分かりにくい)。
          -- +/* の読み戻しはしない: command provider ('cat' 等) では getreg('+')が
          -- provider 側の paste 実行に依存し、CI (Linux) と local (macOS) で成否が
          -- 分かれる (実測)。setreg('+') 自体は Neovim 標準動作であり、実環境での
          -- クリップボード載りは e2e / 手動確認の担当 (ai-prompt.md 検証方針)。
          assert.same({
            msg = 'review.nvim: 1 件のコメントをクリップボードにコピーしました',
            level = vim.log.levels.INFO,
          }, state.notifications[1], case.name .. ': コピー成功 INFO')
          assert.equals(1, #state.notifications, case.name .. ': 通知はコピー INFO のみ')
        end
      end
    end
  )

  it(
    'provider ありで outdated 混在では除外 INFO → コピー完了 INFO の順で計 2 件',
    function()
      -- has_provider 検出元 1 系統 (command provider 定義)。probe は before_each で
      -- false のままなので成功経路は provider 検出でしか通らない = arrange 漏れは
      -- 無し経路化 (WARN が先頭) してこの assert が落ちる。
      vim.g.clipboard = {
        type = 'command',
        copy = { ['+'] = 'cat', ['*'] = 'cat' },
        paste = { ['+'] = 'cat', ['*'] = 'cat' },
      }
      seed {
        comment('c1', 'a.lua', 2, nil, 'keep'),
        comment('c2', 'a.lua', 3, nil, 'stale', 'outdated'),
      }
      state.notifications = {}

      local res = prompt_handler.all()

      assert.same({
        __class = 'review.Result',
        ok = true,
        data = { text = full_prompt { '@a.lua#L2', 'keep' }, count = 1 },
      }, res)
      assert.same({
        msg = 'review.nvim: 1 件を除外しました (outdated)',
        level = vim.log.levels.INFO,
      }, state.notifications[1], '除外 INFO が先')
      assert.same({
        msg = 'review.nvim: 1 件のコメントをクリップボードにコピーしました',
        level = vim.log.levels.INFO,
      }, state.notifications[2], 'コピー完了 INFO が後')
      assert.equals(2, #state.notifications)
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
    vim.api.nvim_set_current_win(state.head_win)
    vim.api.nvim_win_set_cursor(state.head_win, { row, 0 })
  end

  it('y: 見出しなしで @path#L.. と本文を "0 に入れる', function()
    seed { comment('c1', 'a.lua', 2, 3, 'use map') }
    focus_row(3) -- 恒等行 'three' = new 3 (range 2-3 の内側)

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
    focus_row(2)

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
    focus_row(2)

    comments_handler.yank_current()

    assert.same({
      msg = 'review.nvim: 1 件を除外しました (outdated)',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals('@a.lua#L2-L3\nmulti', vim.fn.getreg '0')
  end)

  it('y: コメントが無い行では既存の WARN で "0 を触れない', function()
    focus_row(5) -- 恒等行 'six' = new 5、コメント無し

    comments_handler.yank_current()

    assert.same({
      msg = 'review.nvim: その行のコメントはありません',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(SENTINEL, vim.fn.getreg '0')
  end)
end)
