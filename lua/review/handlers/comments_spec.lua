-- handlers/comments: c / e / d 操作フロー (diff-review.md「操作」)。
-- 検証の中心は (1) 作成された Comment の契約 (id 採番 / range / anchor 生成)、
-- (2) 操作直後の永続化 (INV-4: ディスクを読んで判定)、(3) 不可行時の WARN。
-- 入力 float は :normal キーシーケンスで実経路を駆動する (ui/input_spec と同じ前提)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local comments_handler = require 'review.handlers.comments'
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'

local REPO_TOP = '/spec/repo-top'
local SLUG = 'main--feature'
local DIFF_A_NAME = 'review://diff/' .. SLUG .. '/a.lua'

local CY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

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
    state = { notifications = {}, inputs = {}, input_answer = 'y' }
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
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    -- セッションを開始し、右ペインの diff バッファにフォーカスする
    -- (UI = sidebar + diff の 2 窓。float が開いたときのみ +1)
    session_handler.start { base = 'main', head = 'feature' }
    state.session = session_handler.active()
    state.diff_buf = vim.fn.bufnr(DIFF_A_NAME)
    state.diff_win = vim.fn.win_findbuf(state.diff_buf)[1]
    vim.api.nvim_set_current_win(state.diff_win)
    -- buffer 行 -> new 側行の対応はこの diff での事実: row3=' one'(new1)
    -- row4='+two'(2) row5='+three'(3) row6=' four'(4) row7='-five'(del) row8=' six'(5)
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

local function focus_diff_row(row)
  vim.api.nvim_win_set_cursor(state.diff_win, { row, 0 })
end

local function saved()
  return store.load(REPO_TOP, SLUG).data
end

-- 現在開いている入力 float で本文を打鍵し <C-y> で確定する (実キー経路)。
local function type_into_float(body)
  vim.cmd('normal i' .. body .. CY)
end

-- visual selection の '< /> marks を明示設定する (:normal Vj と異なり
-- busted + 実 UI 環境での打鍵合成は不安定 — キー発火自体は
-- dbg で検証済み、mapping 登録は ui/diffbuffer_spec、実打鍵は e2e が担保)。
local function set_visual_marks(r1, r2)
  local buf = vim.api.nvim_win_get_buf(state.diff_win)
  vim.cmd([[call setpos("'<", []] .. buf .. [[, ]] .. r1 .. [[, 0, 0])]])
  vim.cmd([[call setpos("'>", []] .. buf .. [[, ]] .. r2 .. [[, 0, 0])]])
end

describe('comments c (作成)', function()
  use_env()

  it('カーソル行 (+ 行) のコメントを作成: id/range/anchor/save/表示', function()
    focus_diff_row(4) -- '+two' = new 2
    comments_handler.add_normal()
    type_into_float 'use map here'

    assert.same({
      id = 'c1',
      file = 'a.lua',
      line = 2,
      end_line = 2,
      body = 'use map here',
      anchor = { before = 'one', line = 'two', after = 'three' },
      state = 'active',
      created_at = 4321,
    }, saved().comments[1])
    -- extmark 再描画: row4 (0-based 3) に下線 + 💬 抜粋 (行テキストは変わらない、
    -- 表示は extmark virt text)。
    local ns = vim.api.nvim_get_namespaces()['review_comment']
    local marks = vim.api.nvim_buf_get_extmarks(state.diff_buf, ns, 0, -1, { details = true })
    assert.equals(' 💬 use map here', marks[1][4].virt_text[1][1])
    -- save は操作直後 (INV-4)
    assert.equals(4321, saved().updated_at)
    assert.equals(0, #state.notifications)
  end)

  it('コンテキスト行でも作成できる (new 側に行が存在すれば可)', function()
    focus_diff_row(3) -- ' one' = new 1、before は不存在
    comments_handler.add_normal()
    type_into_float 'ctx comment'

    local c = saved().comments[1]
    assert.same({ before = vim.NIL, line = 'one', after = 'two' }, c.anchor)
    assert.equals(1, c.line)
  end)

  it('- 行では WARN で float を開かない (new 側行番号が無い)', function()
    focus_diff_row(7) -- '-five'
    comments_handler.add_normal()

    assert.same({
      msg = 'review.nvim: この行は new 側に存在しないためコメントを付けられません (削除行 / diff ヘッダ)',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(0, #saved().comments)
    -- 打ち込む float は開いていない (UI 2 窓のまま)
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(state.tab))
  end)

  it('ファイルヘッダ行でも開かない', function()
    focus_diff_row(1)
    comments_handler.add_normal()
    assert.same({
      msg = 'review.nvim: この行は new 側に存在しないためコメントを付けられません (削除行 / diff ヘッダ)',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(0, #saved().comments)
  end)

  it('visual-line 範囲では先頭〜末尾 new 側行が range になる', function()
    focus_diff_row(4)
    set_visual_marks(4, 5) -- '+two'..'+three' = new 2..3
    comments_handler.add_visual_marks()
    type_into_float 'range note'

    local c = saved().comments[1]
    assert.same({ line = 2, end_line = 3, body = 'range note' }, {
      line = c.line,
      end_line = c.end_line,
      body = c.body,
    })
    assert.same({ before = 'one', line = 'two', after = 'three' }, c.anchor)
  end)

  it('visual 選択が削除専用行だけなら WARN で拒否', function()
    focus_diff_row(7)
    set_visual_marks(7, 7) -- '-five' 単一行 = 削除専用
    comments_handler.add_visual_marks()
    assert.same({
      msg = 'review.nvim: 選択に new 側行がありません',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    -- float は開いていない
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(state.tab))
  end)

  it('作成を <Esc> で取消したら何も作らない', function()
    focus_diff_row(4)
    comments_handler.add_normal()
    vim.cmd 'normal iunsent'
    vim.cmd('normal ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))

    assert.equals(0, #saved().comments)
  end)

  it('入力 float の title に対象の path:line が表示される', function()
    focus_diff_row(4) -- '+two' = new 2
    comments_handler.add_normal()
    local t = vim.api.nvim_win_get_config(0).title
    local text = type(t) == 'table' and (type(t[1]) == 'table' and t[1][1] or t[1]) or (t or '')
    assert.is_true(text:find('a.lua:2', 1, true) ~= nil)
    -- 本文なし q = 即時閉 (窓掃除)
    vim.cmd('normal ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true) .. 'q')
  end)

  it('2 件目の id は max+1 採番', function()
    focus_diff_row(4)
    comments_handler.add_normal()
    type_into_float 'first'

    focus_diff_row(5)
    comments_handler.add_normal()
    type_into_float 'second'

    assert.same({ 'c1', 'c2' }, { saved().comments[1].id, saved().comments[2].id })
  end)
end)

describe('comments e (編集) / d (削除)', function()
  use_env()

  local function seed_one(body)
    focus_diff_row(4)
    comments_handler.add_normal()
    type_into_float(body or 'origin')
  end

  it('e: カーソル行 1 件を事前入力 float で更新 -> anchor 不変 + save', function()
    seed_one 'origin'
    focus_diff_row(4)
    comments_handler.edit_current()

    -- float には body が事前入力されている
    assert.same({ 'origin' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd 'normal 0d$'
    type_into_float 'edited'

    local c = saved().comments[1]
    assert.equals('edited', c.body)
    assert.same({ before = 'one', line = 'two', after = 'three' }, c.anchor)
    assert.equals(1, #saved().comments)
  end)

  it('e: 複数件は vim.ui.select で対象を選ぶ', function()
    focus_diff_row(4)
    comments_handler.add_normal()
    type_into_float 'first'
    -- 同じ new 行にもう 1 件 (range を広げて重なる)
    table.insert(state.session.comments, {
      id = 'c2',
      file = 'a.lua',
      line = 2,
      end_line = 4,
      body = 'second',
      anchor = vim.NIL,
      state = 'active',
      created_at = 4321,
    })

    local selected_body = nil
    local real_select = vim.ui.select
    vim.ui.select = function(items, _opts, on_choice)
      selected_body = #items
      on_choice(items[2])
    end
    focus_diff_row(4)
    comments_handler.edit_current()
    assert.equals(2, selected_body)
    vim.cmd 'normal 0d$'
    type_into_float 'chose second'
    vim.ui.select = real_select

    local by_id = {}
    for _, c in ipairs(saved().comments) do
      by_id[c.id] = c.body
    end
    assert.same({ c1 = 'first', c2 = 'chose second' }, by_id)
  end)

  it('e: カーソル行にコメントがなければ WARN', function()
    focus_diff_row(8) -- ' six' = new 5、コメント無し
    comments_handler.edit_current()
    assert.same({
      msg = 'review.nvim: その行のコメントはありません',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
  end)

  -- UX review F9: vim 筋 dd が「d 2 回」= 複数を無確認で消せた事故の再発防止。
  -- 1 目は armed のみ、同じコメントへ 2 度目で削除 (window 内)。
  it('d: 1 目は削除せず armed + WARN、同じ行 2 度目で削除 -> save', function()
    seed_one()
    focus_diff_row(4)
    comments_handler.delete_current()

    assert.equals(1, #saved().comments) -- まだ消えていない
    assert.equals('warn', state.notifications[1].level == vim.log.levels.WARN and 'warn' or 'FAIL')

    comments_handler.delete_current()
    assert.equals(0, #saved().comments)
    local ns = vim.api.nvim_get_namespaces()['review_comment']
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(state.diff_buf, ns, 0, -1, {}))
  end)

  it('d: armed が discard window を過ぎると 1 目に戻る', function()
    seed_one()
    focus_diff_row(4)
    local t = 100
    comments_handler._set_now(function()
      return t
    end)
    comments_handler.delete_current()
    t = t + 3
    comments_handler.delete_current()
    assert.equals(1, #saved().comments) -- 再 armed (window 外)
    comments_handler.delete_current()
    assert.equals(0, #saved().comments)
    comments_handler._set_now(nil)
  end)

  it('d: 別行へ移動すると arming はその行に切り替わる', function()
    seed_one() -- c1 @ new 2 (row 4)
    focus_diff_row(5) -- '+three' = new 3 にコメント無し -> ここは arming 対象なし
    -- (comments_at_cursor が WARN)
    comments_handler.delete_current()
    assert.equals(
      'review.nvim: その行のコメントはありません',
      state.notifications[1].msg
    )
    assert.equals(1, #saved().comments)
  end)

  -- dd = d 2 回。arming により「同一行なら 1 件しか消えない」ことを担保
  -- (旧実装は無確認即時削除で複数件吹き飛んだ — UX review F9)。
  it('d 連打 (dd 相当) でも同一行のコメントは 1 件しか消えない', function()
    comments_handler._set_now(function()
      return 100
    end)
    seed_one 'first'
    focus_diff_row(4)
    comments_handler.add_normal()
    type_into_float 'second' -- 同じ new 行に 2 件目

    focus_diff_row(4)
    comments_handler.delete_current()
    comments_handler.delete_current()

    assert.equals(1, #saved().comments)
    comments_handler._set_now(nil)
  end)

  it('d: コメントなしは WARN で save 内容不変', function()
    focus_diff_row(8)
    comments_handler.delete_current()
    assert.same({
      msg = 'review.nvim: その行のコメントはありません',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(0, #saved().comments)
  end)
end)
