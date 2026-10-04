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
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'
local fixtures = require 'helpers.fixtures'
local git_env = require 'helpers.git_env'
local nvim_env = require 'helpers.nvim_env'
local session_env = require 'helpers.session_env'

local SLUG = 'main--feature'

local REAL_INPUT = nvim_env.REAL_INPUT
local CY = nvim_env.CY

-- head (作業ツリー) の a.lua = new 側 5 行。実 repo dir の disk と同じ内容に
-- する (head 実ファイル窓は :edit 相当の実在ファイル経路なので磁盘実在が前提)。
local HEAD_TEXT = fixtures.HEAD_TEXT_ONE_SIX

local RAW_DIFF = fixtures.RAW_DIFF_ONE_SIX

local state = {}

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, input_answer = 'y' }
    -- 実 repo に見せた dir (head 実ファイルがディスクに実在する = 通常経路)
    session_env.make_dirs(state, { ['a.lua'] = HEAD_TEXT })
    session_env.inject_store(state)
    comments_handler._set_now(function()
      return 4321
    end)
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
    git_env.executable_ok()
    state.tab = vim.api.nvim_get_current_tabpage()
    session_env.capture_notify(state)
    session_handler.start { base = 'main', head = 'feature' }
    state.session = session_handler.active()
    -- head 実ファイル窓 (専有 tab 開通後 focus == head 窓)
    state.head_buf = vim.fn.bufnr(vim.fs.joinpath(state.repo, 'a.lua'))
    state.head_win = ui_windows.win 'head'
    vim.api.nvim_set_current_win(state.head_win)
    -- 恒等行: head バッファの行 N = new 側行 N (1 one / 2 two / 3 three / 4 four / 5 six)
  end)
  after_each(function()
    session_env.close_session()
    session_env.reset_windows()
    nvim_env.close_all_tabs()
    nvim_env.wipe_review_buffers()
    comments_handler._set_now(nil)
    session_env.release(state)
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
        local function line_text(chunks)
          local parts = {}
          for _, chunk in ipairs(chunks or {}) do
            parts[#parts + 1] = text_of(chunk)
          end
          return table.concat(parts)
        end
        local vt = m[4].virt_text and text_of(m[4].virt_text[1]) or ''
        if type(vt) == 'string' and vt:find('\u{EA6B}', 1, true) ~= nil then
          found_cnt = true
        end
        for _, vl in ipairs(m[4].virt_lines or {}) do
          local t = line_text(vl)
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
    'base 窓の c はコメントを作らず確定 WARN («comments are not available in this window»)',
    function()
      vim.api.nvim_set_current_win(ui_windows.win 'base')
      state.notifications = {}
      comments_handler.add_normal()
      assert.same({
        msg = 'review.nvim: comments are not available in this window',
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
      msg = 'review.nvim: no active session',
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
      msg = 'review.nvim: no comments on this line',
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
      msg = 'review.nvim: to delete comment c1 press d again on this '
        .. 'line (cancel: move to another line / wait 2s / press <Esc>)',
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

  it(
    'd: 複数該当 (根 + リプライ同線) は picker で選んだ時点でそのコメントだけ削除',
    function()
      focus_head_row(2)
      comments_handler.add_normal()
      type_into_float 'root'
      table.insert(state.session.comments, {
        id = 'c2',
        file = 'a.lua',
        line = 2,
        end_line = 2,
        body = 'reply',
        anchor = vim.NIL,
        state = 'active',
        origin = 'local',
        in_reply_to = 'c1',
        created_at = 4321,
      })
      -- メモリ上の active セッションに根 + リプライが並ぶ (disk 反映は削除確定時の
      -- persist で確認する — INV-4 は「効果直後にディスクを読んで判定」)
      assert.equals(2, #state.session.comments)

      -- picker でリプライ (2 件目) を選ぶ -> 明示選択 = 即削除 (arm 不要)
      local seen = nil
      local real_select = vim.ui.select
      vim.ui.select = function(items, _opts, on_choice)
        seen = #items
        on_choice(items[2])
      end
      focus_head_row(2)
      comments_handler.delete_current()
      vim.ui.select = real_select
      assert.equals(2, seen, 'ui.select に複数件が渡っていない')
      assert.equals(1, #saved().comments) -- 選んだリプライだけが消え、根は残る
      assert.equals('c1', saved().comments[1].id)
      assert.equals('root', saved().comments[1].body)
    end
  )

  it('d: 複数該当の picker をキャンセル (Esc) すると何も削除しない', function()
    focus_head_row(2)
    comments_handler.add_normal()
    type_into_float 'root'
    table.insert(state.session.comments, {
      id = 'c2',
      file = 'a.lua',
      line = 2,
      end_line = 2,
      body = 'reply',
      anchor = vim.NIL,
      state = 'active',
      origin = 'local',
      in_reply_to = 'c1',
      created_at = 4321,
    })
    assert.equals(2, #state.session.comments)

    vim.ui.select = function(_items, _opts, on_choice)
      on_choice(nil) -- キャンセル
    end
    focus_head_row(2)
    comments_handler.delete_current()

    assert.equals(2, #state.session.comments) -- 何も消えない
  end)
end)

describe('comments D / clear_by_command (一括削除)', function()
  use_env()

  local function seed(count, start_row)
    for i = 1, count do
      focus_head_row((start_row or 2) + i - 1)
      comments_handler.add_normal()
      type_into_float('x' .. i)
    end
    state.notifications = {}
  end

  it('D: arming 二重押しで全件削除 + save + INFO (outdated も消える)', function()
    seed(2)
    -- outdated を 1 件混ぜる (state はセッション上の実値。削除は state 無関係)
    state.session.comments[1].state = 'outdated'

    comments_handler.delete_all_arming()
    assert.same({
      msg = 'review.nvim: to delete all 2 comments press again '
        .. '(cancel: wait 2s / comment count change / press <Esc>)',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(1, #state.notifications)
    assert.equals(2, #saved().comments)

    comments_handler.delete_all_arming()
    assert.same({
      msg = 'review.nvim: deleted all 2 comments',
      level = vim.log.levels.INFO,
    }, state.notifications[2])
    -- INV-4: ディスクの JSON が空になる
    assert.equals(0, #saved().comments)
  end)

  it('D: 2 秒窓を過ぎた 2 回目は 1 目に戻る (消さない)', function()
    seed(1)
    local clock = 100
    comments_handler._set_now(function()
      return clock
    end)
    comments_handler.delete_all_arming()
    clock = clock + 3
    comments_handler.delete_all_arming() -- 窓外 = 再 arming
    assert.equals(1, #saved().comments)
    comments_handler.delete_all_arming() -- 同一窓 2 回目で全消し
    assert.equals(0, #saved().comments)
    comments_handler._set_now(function()
      return 4321
    end)
  end)

  it('D: arming 中にコメントが増えると無効 (2 回押しても消えない)', function()
    seed(2)
    comments_handler.delete_all_arming() -- armed n=2
    focus_head_row(5)
    comments_handler.add_normal()
    type_into_float 'added' -- n=3 に変化 = arming 解除
    state.notifications = {}

    comments_handler.delete_all_arming() -- 1 目扱い (n=3)
    assert.equals(3, #saved().comments)
    assert.same({
      msg = 'review.nvim: to delete all 3 comments press again '
        .. '(cancel: wait 2s / comment count change / press <Esc>)',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
  end)

  it('D: 0 件は INFO «No comments» で arming しない', function()
    comments_handler.delete_all_arming()
    assert.same({
      msg = 'review.nvim: No comments',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals(1, #state.notifications)
  end)

  it('clear_by_command: y 応答で全件削除 + save + INFO', function()
    seed(2)
    vim.ui.input = function(opts, cb)
      state.confirm_prompt = opts.prompt
      cb 'y'
    end
    local res = comments_handler.clear_by_command()
    vim.ui.input = REAL_INPUT

    assert.equals(true, res.ok)
    assert.equals(
      'review.nvim: delete all 2 comments? (includes outdated; deletion cannot be undone) [y/N]: ',
      state.confirm_prompt
    )
    assert.equals(0, #saved().comments)
    assert.same({
      msg = 'review.nvim: deleted all 2 comments',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
  end)

  it(
    'clear_by_command: n 応答は何も消さない (close の確認と同じく無通知)',
    function()
      seed(2)
      vim.ui.input = function(_, cb)
        cb 'n'
      end
      local res = comments_handler.clear_by_command()
      vim.ui.input = REAL_INPUT

      assert.equals(true, res.ok)
      assert.same({}, state.notifications)
      assert.equals(2, #saved().comments)
    end
  )

  it('clear_by_command: 0 件は確認せず INFO «No comments»', function()
    local confirmed = false
    vim.ui.input = function(_, cb)
      confirmed = true
      cb 'y'
    end
    local res = comments_handler.clear_by_command()
    vim.ui.input = REAL_INPUT

    assert.equals(true, res.ok)
    assert.equals(false, confirmed)
    assert.same({
      msg = 'review.nvim: No comments',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
  end)

  it('clear_by_command: active 不在は E_NOT_ACTIVE (窓の有無は無関係)', function()
    session_handler.close()
    local res = comments_handler.clear_by_command()
    assert.same({
      __class = 'review.Result',
      ok = false,
      error = 'review.nvim: no active session',
      code = 'E_NOT_ACTIVE',
    }, res)
  end)
end)

describe('comments <Esc> cancel_arming (arming 解除)', function()
  use_env()

  local function seed2()
    -- 前テストからの arming 残骸 (モジュール状態は spec 間で共有される) を吸う
    comments_handler.cancel_arming()
    for _, row in ipairs { 2, 3 } do
      focus_head_row(row)
      comments_handler.add_normal()
      type_into_float('x' .. row)
    end
    state.notifications = {}
  end

  it('d: arming 中の <Esc> で解除 (true + INFO)。次回押下は 1 目に戻る', function()
    seed2()
    focus_head_row(2)
    comments_handler.delete_current() -- d arming
    state.notifications = {}

    assert.is_true(comments_handler.cancel_arming())
    assert.same({
      msg = 'review.nvim: delete arming cancelled',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals(1, #state.notifications)
    assert.equals(2, #saved().comments)

    -- 解除済み = 次の d は 1 目 (arming WARN のみで消えない)
    focus_head_row(2)
    comments_handler.delete_current()
    assert.equals(2, #saved().comments)
  end)

  it('D: arming 中の <Esc> で解除。次回押下は 1 目に戻る', function()
    seed2()
    comments_handler.delete_all_arming() -- D arming (n=2)
    state.notifications = {}

    assert.is_true(comments_handler.cancel_arming())
    assert.same({
      msg = 'review.nvim: delete arming cancelled',
      level = vim.log.levels.INFO,
    }, state.notifications[1])

    comments_handler.delete_all_arming() -- 1 目扱い、まだ消えない
    assert.equals(2, #saved().comments)
  end)

  it('d と D を同時に armed にしていても 1 回の <Esc> で両方解除', function()
    seed2()
    focus_head_row(2)
    comments_handler.delete_current()
    comments_handler.delete_all_arming()
    state.notifications = {}

    assert.is_true(comments_handler.cancel_arming())
    assert.equals(1, #state.notifications) -- INFO は 1 件だけ
    focus_head_row(2)
    comments_handler.delete_current() -- 両方 1 目に戻っている
    comments_handler.delete_all_arming()
    assert.equals(2, #saved().comments)
  end)

  it('arming されていない <Esc> は false (通知せず built-in へ返す)', function()
    comments_handler.cancel_arming() -- 前テスト残骸の arm を吸う
    state.notifications = {}

    assert.is_false(comments_handler.cancel_arming())
    assert.same({}, state.notifications)
  end)
end)

describe('comments y / i', function()
  use_env()

  -- 右寄せ pad を除いた中身 (表示行)。罫線は nvim の float border が描くため
  -- buffer 行の比較は padding だけを剥がす (幅は columns 依存)。
  local function view_content(line)
    return (line:gsub('%s+$', ''))
  end

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

  it(
    'i: 全文閲覧 float を開く (メタデータ行 + 本文は 2 行目から左寄せ)',
    function()
      seed_at(2, 'view me\nsecond line')

      focus_head_row(2)
      state.notifications = {}
      comments_handler.view_current()
      local wins = vim.api.nvim_tabpage_list_wins(ui_windows.state().tab)
      -- 3 レビュー窓 + 閲覧 float (罫線は nvim border) = 4
      assert.equals(4, #wins, '閲覧 float が開かない (3 レビュー窓 + float)')
      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      -- 罫線は nvim の float border (rounded + title)。buffer は中身だけで、
      -- 1 コメント = メタデータ行 + 本文 (2 行目から左寄せ)
      local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
      assert.same({ '╭', '─', '╮', '│', '╯', '─', '╰', '│' }, cfg.border)
      assert.equals(' Comment a.lua q close ', cfg.title[1][1])
      assert.equals('a.lua:2 [c1]', view_content(lines[1]))
      assert.equals('view me', view_content(lines[2]))
      assert.equals('second line', view_content(lines[3]))
      -- buffer に罫線文字は無い (カーソルが罫線に乗らない)
      for _, line in ipairs(lines) do
        assert.is_true(line:find('│', 1, true) == nil, 'buffer に罫線 │ がある')
      end
      assert.equals('markdown', vim.bo[buf].filetype)
      assert.equals(0, #state.notifications)
    end
  )

  it(
    'i: gh コメントは作者 login をメタデータ行に表示し、コメント間に全幅 ─ 区切りを入れる',
    function()
      seed_at(2, 'root')
      table.insert(state.session.comments, {
        id = 'c2',
        file = 'a.lua',
        line = 2,
        end_line = 2,
        body = '[must]\ntext',
        anchor = vim.NIL,
        state = 'active',
        origin = 'gh',
        gh_id = 10,
        gh_user = 'skanehira',
        gh_state = 'submitted',
        created_at = 4321,
      })
      focus_head_row(2)
      comments_handler.view_current()

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      -- c1: メタデータ / 本文。c2: メタデータ / [must] / text (severity は本文の一部)
      assert.equals('a.lua:2 [c1]', view_content(lines[1]))
      assert.equals('root', view_content(lines[2]))
      assert.equals('a.lua:2 [skanehira]', view_content(lines[4]))
      assert.equals('[must]', view_content(lines[5]))
      assert.equals('text', view_content(lines[6]))
      -- 区切りは内容幅いっぱいの `─` 罫線行 (左右は nvim border の │ が残る)。
      -- マルチバイト ─ の繰り返しは Lua パターンの + では扱えないため gsub で判定。
      assert.equals('', (lines[3]:gsub('─', '')))
      assert.is_true(vim.fn.strchars(lines[3]) > 3, '区切りが全幅展開されていない')
      assert.is_true(lines[3]:find('│', 1, true) == nil, 'buffer に罫線 │ がある')
    end
  )

  it('i: outdated コメントは prompt 除外中と表示する', function()
    seed_at(2, 'drifted')
    local session = session_handler.active()
    session.comments[1].state = 'outdated'

    focus_head_row(2)
    comments_handler.view_current()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    -- メタデータ行に除外中の注記が載り、本文は次の行 (左寄せ)
    assert.equals('a.lua:2 [c1]  ! outdated (excluded from prompt)', view_content(lines[1]))
    assert.equals('drifted', view_content(lines[2]))
  end)
end)

describe('comments [c / ]c (前後のコメントへジャンプ)', function()
  use_env()

  local function seed_at(row, body)
    focus_head_row(row)
    comments_handler.add_normal()
    type_into_float(body)
  end

  local function cursor_row()
    return vim.api.nvim_win_get_cursor(state.head_win)[1]
  end

  it(
    'c]: カーソル行より後の最初のコメント開始行へジャンプ (同行情は飛ばす)',
    function()
      seed_at(2, 'first')
      seed_at(2, 'second') -- 同一行の別コメント (群)
      seed_at(4, 'third')

      focus_head_row(1)
      comments_handler.next_comment()
      assert.equals(2, cursor_row(), '1 -> 最初のコメント')

      focus_head_row(2)
      comments_handler.next_comment()
      assert.equals(4, cursor_row(), '同行情の 2 件目は飛ばして次の行へ')

      -- 範囲コメント: 開始行へジャンプする
      focus_head_row(3)
      set_visual_marks(3, 4)
      comments_handler.add_visual_marks()
      type_into_float 'range'
      focus_head_row(3)
      comments_handler.next_comment()
      assert.equals(4, cursor_row(), '範囲コメントは開始行 (4) へ')
    end
  )

  it('c[: カーソル行より前の最後のコメント開始行へジャンプ', function()
    seed_at(2, 'first')
    seed_at(4, 'second')

    focus_head_row(5)
    comments_handler.prev_comment()
    assert.equals(4, cursor_row(), '5 -> 直前のコメント')

    focus_head_row(4)
    comments_handler.prev_comment()
    assert.equals(2, cursor_row(), '4 -> さらに前へ')
  end)

  it(
    '端では clamp (no-op): 先頭より上で [c / 末尾より下で ]c は何もしない',
    function()
      seed_at(2, 'only')
      seed_at(4, 'second')

      focus_head_row(1)
      comments_handler.prev_comment()
      assert.equals(1, cursor_row(), '先頭より上は no-op')

      focus_head_row(5)
      comments_handler.next_comment()
      assert.equals(5, cursor_row(), '末尾より下は no-op')
    end
  )

  it('base 窓では WARN してジャンプしない (head 窓のみ)', function()
    seed_at(2, 'base check')
    local base_win = ui_windows.win 'base'
    vim.api.nvim_set_current_win(base_win)
    vim.api.nvim_win_set_cursor(base_win, { 1, 0 })
    state.notifications = {}

    comments_handler.next_comment()
    assert.equals(1, vim.api.nvim_win_get_cursor(base_win)[1], 'カーソルは動かない')
    assert.same({
      {
        msg = 'review.nvim: comments are not available in this window',
        level = vim.log.levels.WARN,
      },
    }, state.notifications)
  end)
end)

describe('comments r (返信 / local pending)', function()
  use_env()

  it(
    'カーソル行スレッドへ返信: in_reply_to=gh 根の id を持つ local pending を追加・save',
    function()
      local sess = session_handler.active()
      sess.comments = {
        {
          id = 'c1',
          file = 'a.lua',
          line = 2,
          end_line = 2,
          body = 'root',
          origin = 'gh',
          gh_id = 101,
          in_reply_to = nil,
        },
      }
      session_handler.commit_comment_change()
      focus_head_row(2)
      comments_handler.reply_at_cursor()
      type_into_float 'my reply'

      local comments = saved().comments
      assert.equals(2, #comments)
      local c = comments[2]
      assert.equals('c2', c.id)
      assert.equals('a.lua', c.file)
      assert.equals(2, c.line)
      assert.equals(2, c.end_line)
      assert.equals('my reply', c.body)
      assert.equals('local', c.origin)
      assert.equals(101, c.in_reply_to)
      assert.is_nil(c.gh_id)
    end
  )

  it('スレッドが無い行は WARN で開かない', function()
    focus_head_row(4)
    comments_handler.reply_at_cursor()
    assert.same({
      msg = 'review.nvim: no thread to reply to on this line',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(0, #saved().comments)
  end)
end)
