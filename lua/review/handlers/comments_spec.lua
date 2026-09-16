-- handlers/comments: c / e / d / y / i 操作フロー (diff-review.md「操作」/
-- DESIGN.md「デフォルトキーマップ」)。契約の要点:
--   * 行写像は恒等 — head 実ファイル (縮退時は head scratch) バッファの行番号 =
--     new 側行番号そのもの (INV-2。unified 自前行写像は撤廃)。
--   * 不可窓 (base / 告知 scratch) の c 系は確定文言 «この窓にはコメントを
--     付けられません» の WARN で開かない。
-- 検証の中心は (1) 作成された Comment の契約 (id 採番 / range / anchor 生成)、
-- (2) 操作直後の永続化 (INV-4: ディスクを読んで判定)、(3) 不可行時の WARN。
-- 入力 float は :normal キーシーケンスで実経路を駆動する。
local cli = require 'review.git.cli'
local config = require 'review.config'
local comments_handler = require 'review.handlers.comments'
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'

local SLUG = 'main--feature'

-- プロセス単一の vim 組み込みを require 時に 1 回捕捉 (before_each ごとに見ると
-- spy が入れ子になり after_each の復旧先が壊れる — session_spec と同型)。
local CY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

-- head (作業ツリー) の a.lua = new 側 5 行。実 repo dir の disk と同じ内容に
-- する (head 実ファイル窓は :edit 相当の実在ファイル経路なので磁盘実在が前提)。
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

local state = {}

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, input_answer = 'y' }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    -- 実 repo に見せた dir (head 実ファイルがディスクに実在する = 通常経路)
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
    state.tab = vim.api.nvim_get_current_tabpage()
    state.real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    session_handler.start { base = 'main', head = 'feature' }
    state.session = session_handler.active()
    -- head 実ファイル窓 (専有 tab 開通後 focus == head 窓)
    state.head_buf = vim.fn.bufnr(vim.fs.joinpath(state.repo, 'a.lua'))
    state.head_win = ui_windows.win 'head'
    vim.api.nvim_set_current_win(state.head_win)
    -- 恒等行: head バッファの行 N = new 側行 N (1 one / 2 two / 3 three / 4 four / 5 six)
  end)
  after_each(function()
    -- close はコメントあり確認 (1 キー float) を引く。headless では応答スタブ。
    session_handler._set_confirm(function(_, cb)
      cb(true)
    end)
    session_handler.close()
    session_handler._set_confirm(nil)
    if ui_windows.state() ~= nil then
      ui_windows.close()
    end
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
    vim.notify = state.real_notify
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

local function focus_head_row(row)
  vim.api.nvim_set_current_win(state.head_win)
  vim.api.nvim_win_set_cursor(state.head_win, { row, 0 })
end

local function saved()
  return store.load(state.repo, SLUG).data
end

-- 現在開いている入力 float で本文を打鍵し <C-y> で確定する (実キー経路)。
local function type_into_float(body)
  vim.cmd('normal i' .. body .. CY)
end

-- visual selection の '< /> marks を head バッファ行に明示設定する (:normal Vj と
-- 異なり busted + 実 UI 環境での打鍵合成は不安定 — 実打鍵の発火単位は e2e が担保)。
local function set_visual_marks(r1, r2)
  local buf = vim.api.nvim_win_get_buf(state.head_win)
  vim.cmd([[call setpos("'<", []] .. buf .. [[, ]] .. r1 .. [[, 0, 0])]])
  vim.cmd([[call setpos("'>", []] .. buf .. [[, ]] .. r2 .. [[, 0, 0])]])
end

describe('comments c (作成 / head バッファ恒等行)', function()
  use_env()

  it(
    'カーソル行のコメントを作成: line=buffer 行 (恒等) / anchor=head 行テキスト / save',
    function()
      focus_head_row(2) -- 'two'
      comments_handler.add_normal()
      type_into_float 'use map here'

      local sess = saved()
      assert.equals(1, #sess.comments)
      local c = sess.comments[1]
      assert.equals('c1', c.id)
      assert.equals('a.lua', c.file)
      assert.equals(2, c.line)
      assert.equals(2, c.end_line)
      assert.equals('use map here', c.body)
      assert.same({ before = 'one', line = 'two', after = 'three' }, c.anchor)
      assert.equals(4321, c.created_at)
      assert.equals('active', c.state)
    end
  )

  it('視覚範囲は min/max の new 側 range (恒等行)', function()
    focus_head_row(2)
    set_visual_marks(2, 4)
    comments_handler.add_visual_marks()
    type_into_float 'range note'

    local c = saved().comments[1]
    assert.equals(2, c.line)
    assert.equals(4, c.end_line)
  end)

  it(
    'live visual (初回選択で < > 未設定) でも現在範囲で開く (Ctrl-V blockwise 含む)',
    function()
      -- 実測: :normal! Vj 直後は mode=V・'< '> = 未設定 (expr mapping は visual を
      -- 抜ける前に評価されるため marks 依存だと初回押下が無反応になる — ユーザー報告)
      focus_head_row(1)
      vim.cmd 'normal! Vj'
      assert.equals('V', vim.fn.mode()) -- 前提: headless でも visual 継続
      assert.same({ 0, 0, 0, 0 }, vim.fn.getpos "'<")

      comments_handler.add_visual_marks()
      type_into_float 'live range'
      local c = saved().comments[1]
      assert.equals(1, c.line)
      assert.equals(2, c.end_line)

      -- Ctrl-V (blockwise) も live 位置から行範囲を取る
      local cv = vim.api.nvim_replace_termcodes('<C-v>', true, false, true)
      focus_head_row(2)
      vim.cmd('normal! ' .. cv .. 'jj')
      assert.equals(string.char(22), vim.fn.mode())
      comments_handler.add_visual_marks()
      type_into_float 'block range'
      local c2 = saved().comments[2]
      assert.equals(2, c2.line)
      assert.equals(4, c2.end_line)
    end
  )

  it('head 実バッファに extmark が載る (件数 eol + 行下スレッド本文)', function()
    focus_head_row(3)
    comments_handler.add_normal()
    type_into_float 'inline thread'

    local ns = vim.api.nvim_get_namespaces().review_comment
    assert.is_true(ns ~= nil)
    local found_cnt, found_body = false, false
    local head_marks = vim.api.nvim_buf_get_extmarks(state.head_buf, ns, 0, -1, { details = true })
    for _, m in ipairs(head_marks) do
      if m[2] == 2 then
        -- chunk は get_extmarks strict 既定 ([text, hl]) で返る (AGENTS virt_text
        -- chunk 教訓の get 側形状)。text = chunk[1] を直接見る。
        local function text_of(chunk)
          if type(chunk) == 'table' then
            local inner = chunk[1]
            return type(inner) == 'table' and inner[1] or inner
          end
          return chunk
        end
        local vt = m[4].virt_text and text_of(m[4].virt_text[1]) or ''
        if type(vt) == 'string' and vt:find('💬', 1, true) ~= nil then
          found_cnt = true
        end
        for _, vl in ipairs(m[4].virt_lines or {}) do
          local t = vl[1] and text_of(vl[1]) or nil
          if type(t) == 'string' and t:find('inline thread', 1, true) ~= nil then
            found_body = true
          end
        end
      end
    end
    assert.is_true(found_cnt, '件数 eol mark が無い')
    assert.is_true(found_body, '行下スレッド本文が無い')
  end)

  it(
    'base 窓の c はコメントを作らず確定 WARN («この窓にはコメントを付けられません»)',
    function()
      vim.api.nvim_set_current_win(ui_windows.win 'base')
      state.notifications = {}
      comments_handler.add_normal()
      assert.same({
        msg = 'review.nvim: この窓にはコメントを付けられません',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.equals(0, #saved().comments)
    end
  )

  it('active セッション無しは WARN で作成しない', function()
    session_handler.close()
    state.notifications = {}
    comments_handler.add_normal()
    assert.same({
      msg = 'review.nvim: アクティブなセッションがありません',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(1, #state.notifications)
  end)
end)

describe('comments e / d (編集・削除 arming)', function()
  use_env()

  local function seed_comment(body)
    focus_head_row(2)
    comments_handler.add_normal()
    type_into_float(body)
  end

  it('e: カーソル行のコメント Body を編集して save', function()
    seed_comment 'orig'
    focus_head_row(2)
    comments_handler.edit_current()
    vim.cmd 'normal 0d$' -- 事前入力行を消してから打ち直す (入力 float 契約)
    type_into_float 'edited'

    assert.equals('edited', saved().comments[1].body)
    assert.is_true(
      vim.bo[state.head_buf].modifiable,
      'head 実窓は編集可でなければならない'
    )
  end)

  it('e: 複数該当は vim.ui.select で対象を選ぶ', function()
    focus_head_row(2)
    comments_handler.add_normal()
    type_into_float 'first'
    table.insert(state.session.comments, {
      id = 'c2',
      file = 'a.lua',
      line = 2,
      end_line = 3,
      body = 'second',
      anchor = vim.NIL,
      state = 'active',
      created_at = 4321,
    })

    local seen = nil
    local real_select = vim.ui.select
    vim.ui.select = function(items, _opts, on_choice)
      seen = #items
      on_choice(items[2])
    end
    focus_head_row(2)
    comments_handler.edit_current()
    vim.ui.select = real_select
    assert.equals(2, seen, 'ui.select に複数件が渡っていない')

    vim.cmd 'normal 0d$' -- 事前入力 (items[2].body) を打ち直す
    type_into_float 'chose second'

    local by_id = {}
    for _, c in ipairs(saved().comments) do
      by_id[c.id] = c.body
    end
    assert.same({ c1 = 'first', c2 = 'chose second' }, by_id)
  end)

  it('e: 該当コメント無しは WARN', function()
    focus_head_row(5)
    state.notifications = {}
    comments_handler.edit_current()
    assert.same({
      msg = 'review.nvim: その行のコメントはありません',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
  end)

  it('d: armed が discard window (2 秒) を過ぎると 1 目に戻る', function()
    focus_head_row(2)
    comments_handler.add_normal()
    type_into_float 'expire me'
    focus_head_row(2)

    local clock = 100
    comments_handler._set_now(function()
      return clock
    end)
    comments_handler.delete_current() -- armed (clock=100)
    clock = clock + 3 -- 窓 (DELETE_ARM_WINDOW_S=2.0) を過ぎる
    comments_handler.delete_current() -- 窓外 = 1 目として再 armed、まだ消えない
    assert.equals(1, #saved().comments)
    comments_handler.delete_current() -- 同一窓 2 回目で削除
    assert.equals(0, #saved().comments)
    comments_handler._set_now(function()
      return 4321
    end)
  end)

  it('d: arming 二重押しで削除 + save (dd で複数消えない)', function()
    focus_head_row(2)
    comments_handler.add_normal()
    type_into_float 'x1'
    focus_head_row(3)
    comments_handler.add_normal()
    type_into_float 'x2'
    assert.equals(2, #saved().comments)

    focus_head_row(2)
    comments_handler.delete_current() -- arming 1 回目
    assert.same({
      msg = 'review.nvim: コメント c1 を削除するには、この行で d をもう一度 (取り消しは他行へ移動か 2 秒待機)',
      level = vim.log.levels.WARN,
    }, state.notifications[#state.notifications])
    assert.equals(2, #saved().comments)

    focus_head_row(3) -- 他行移動 = arming 解除
    comments_handler.delete_current() -- c2 arming
    assert.equals(2, #saved().comments)
    comments_handler.delete_current() -- c2 確定削除
    assert.equals(1, #saved().comments)
    assert.equals('x1', saved().comments[1].body)
  end)
end)

describe('comments y / i', function()
  use_env()

  local function seed_at(row, body)
    focus_head_row(row)
    comments_handler.add_normal()
    -- マルチライン本文は insert 内の <CR> で改行して打鍵する (入力 float 契約)
    local CR = vim.api.nvim_replace_termcodes('<CR>', true, true, true)
    for i, part in ipairs(vim.split(body, '\n', { plain = true })) do
      vim.cmd('normal i' .. part .. (i < #vim.split(body, '\n', { plain = true }) and CR or CY))
    end
  end

  it(
    'y: カーソル行のコメントを "0 へ (クリップボード provider 無しでも)',
    function()
      seed_at(2, 'yank me')
      focus_head_row(2)
      comments_handler.yank_current()
      assert.equals('@a.lua#L2\nyank me', vim.fn.getreg '0')
    end
  )

  it('i: 全文閲覧 float を開く', function()
    seed_at(2, 'view me\nsecond line')

    focus_head_row(2)
    state.notifications = {}
    comments_handler.view_current()
    local wins = vim.api.nvim_tabpage_list_wins(ui_windows.state().tab)
    assert.equals(4, #wins, '閲覧 float が開かない (3 レビュー窓 + float)')
    local buf = vim.api.nvim_get_current_buf()
    assert.same(
      { '[1] c1  a.lua:2', '  view me', '  second line' },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
    assert.equals(0, #state.notifications)
  end)

  it('i: outdated コメントは prompt 除外中と表示する', function()
    seed_at(2, 'drifted')
    local session = session_handler.active()
    session.comments[1].state = 'outdated'

    focus_head_row(2)
    comments_handler.view_current()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.same({ '[1] c1  a.lua:2  ! outdated (prompt 除外中)', '  drifted' }, lines)
  end)
end)
