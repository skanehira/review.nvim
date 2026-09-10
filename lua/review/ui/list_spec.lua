-- ui/list: sidebar (変更ファイル一覧) / :Review list セッション一覧の描画
-- (diff-review.md「sidebar」/ persistence-restore.md「:Review list」)。
-- 行フォーマットと row->データ 引き渡し、viewed [✓]、repo 消失の grey 表示を検証する。
local list = require 'review.ui.list'

local function session_stub(overrides)
  local s = {
    version = 1,
    id = 'main--feature',
    repo = '/repo',
    mode = 'branch',
    base = 'main',
    head = 'feature',
    pr = vim.NIL,
    worktree = vim.NIL,
    status = 'open',
    files = {},
    comments = {},
    created_at = 1,
    updated_at = 1725843600, -- 2024-09-09 09:00:00 (UTC+9 で表示される…は環境 TZ 依存)
  }
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

local state = {}

local function use_env()
  before_each(function()
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    state.win = vim.api.nvim_get_current_win()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
  end)
end

-- 実 git core/diff の parse 相当の最小 File テーブル (list は status/added/deleted のみ使用)。
local function file_stub(path, status, added, deleted)
  return {
    path = path,
    status = status,
    binary = false,
    added = added,
    deleted = deleted,
    hunks = {},
  }
end

describe('list.render_sidebar', function()
  use_env()

  it('パス昇順・`<status> <path> +a -d` 表示で viewed は行頭に [✓]', function()
    local session = session_stub {
      files = { ['b.lua'] = { viewed = true }, ['a.lua'] = { viewed = false } },
    }
    local buf = list.render_sidebar(session, {
      file_stub('b.lua', 'M', 2, 1),
      file_stub('a.lua', 'A', 5, 0),
    })
    assert.same(
      { 'A a.lua +5 -0', '[✓] M b.lua +2 -1' },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
    assert.equals('review-list', vim.bo[buf].filetype)
    assert.equals('review://sidebar/main--feature', vim.api.nvim_buf_get_name(buf))
    assert.same({ kind = 'sidebar', session_id = 'main--feature' }, vim.b[buf].review_meta)
  end)

  it('row_from_line で行のファイルパスを引ける (範囲外は nil)', function()
    local session = session_stub { files = {} }
    local buf = list.render_sidebar(session, {
      file_stub('a.lua', 'M', 1, 0),
      file_stub('c.lua', 'D', 0, 7),
    })
    assert.equals('a.lua', list.row_file(buf, 1))
    assert.equals('c.lua', list.row_file(buf, 2))
    assert.is_nil(list.row_file(buf, 3))
  end)

  it('再 render で行を置き換える (append しない)', function()
    local session = session_stub { files = {} }
    local buf = list.render_sidebar(session, { file_stub('a.lua', 'M', 1, 0) })
    assert.same({ 'M a.lua +1 -0' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    buf = list.render_sidebar(session, {
      file_stub('a.lua', 'M', 1, 0),
      file_stub('z.lua', 'A', 1, 0),
    })
    assert.same({ 'M a.lua +1 -0', 'A z.lua +1 -0' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it('sidebar キー (<CR>/o/x/q) が buffer-local に付く', function()
    local session = session_stub { files = {} }
    local buf = list.render_sidebar(session, { file_stub('a.lua', 'M', 1, 0) })
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      lhs[m.lhs] = true
    end
    for _, key in ipairs { '<CR>', 'o', 'x', 'q' } do
      assert.is_true(lhs[key] == true, 'missing mapping: ' .. key)
    end
  end)

  -- rhs は発火時に解決される文字列 (ui -> handlers の module-load 循環回避)。
  -- key 表の存在だけでなく実 require 解決を検査し、未実装関数の dangling rhs を
  -- 検出する (sidebar o -> fileview.open_from_sidebar の事故の再発防止)。
  local function assert_rhs_callable(buf, keys)
    for _, key in ipairs(keys) do
      local rhs
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == key then
          rhs = m.rhs
        end
      end
      assert.is_not_nil(rhs, 'missing mapping: ' .. key)
      local mod_path, func_name = rhs:match "require%('([^']+)'%)%.([%w_]+)%("
      assert.is_not_nil(
        mod_path,
        ('rhs が require 呼び出し形でない: %s -> %s'):format(key, tostring(rhs))
      )
      local ok_mod, mod = pcall(require, mod_path)
      assert.is_true(ok_mod, 'rhs の require が解決できない: ' .. mod_path)
      assert.equals(
        'function',
        type(mod[func_name]),
        ('%s.%s が関数として解決できない (key=%s)'):format(mod_path, func_name, key)
      )
    end
  end

  it(
    'sidebar の全 keymap rhs は実関数として解決できる (未実装 dangling rhs の検出)',
    function()
      local session = session_stub { files = {} }
      local buf = list.render_sidebar(session, { file_stub('a.lua', 'M', 1, 0) })
      assert_rhs_callable(buf, { '<CR>', 'o', 'x', 'q' })
    end
  )

  it('sessionlist の全 keymap rhs は実関数として解決できる', function()
    local buf = list.render_sessionlist {}
    assert_rhs_callable(buf, { '<CR>', 'q' })
  end)
end)

describe('list.render_sessionlist', function()
  use_env()

  it(
    'slug / status / mode / base..head / コメント数 / 更新時刻の行を slug 昇順で並べる',
    function()
      local sessions = {
        session_stub {
          id = 'z--y',
          base = 'z',
          head = 'y',
          comments = { {}, {} },
          updated_at = 1725843600,
        },
        session_stub { id = 'a--b', base = 'a', head = 'b', updated_at = 1 },
      }
      local buf = list.render_sessionlist(sessions)
      -- 更新時刻はローカル時刻 + tz 表記 (UX review F17)。TZ 絶対値は実行環境
      -- 依存なので「先頭がローカル os.date と一致 + 行末に何か付く」で contract を
      -- 固定し、完全一致は TZ=UTC 相当の意味内容 (日付 + 分単位) を自分で計算する。
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local prefix_a = 'a--b  open  branch  a..b  0 comments  ' .. os.date('%Y-%m-%d %H:%M', 1)
      local prefix_z = 'z--y  open  branch  z..y  2 comments  '
        .. os.date('%Y-%m-%d %H:%M', 1725843600)
      assert.is_true(lines[1]:sub(1, #prefix_a) == prefix_a, lines[1])
      assert.is_true(lines[2]:sub(1, #prefix_z) == prefix_z, lines[2])
      assert.equals('review-list', vim.bo[buf].filetype)
    end
  )

  it(
    'repo 消失セッションは grey hl  extmark が付き open 対象から外れる',
    function()
      local dead = session_stub { id = 'd--d', repo = '/gone' }
      local alive = session_stub { id = 'a--b', repo = vim.fn.getcwd() }
      local buf = list.render_sessionlist({ dead, alive }, {
        is_grey = function(sess)
          return sess.repo == '/gone'
        end,
      })
      local ns = vim.api.nvim_get_namespaces()['review_list_grey']
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.equals(1, #marks)
      assert.equals(1, marks[1][2]) -- slug 昇順 2 行目 (d--d) が grey
      assert.equals('ReviewSidebarStatus', marks[1][4].hl_group)
      -- row_session は grey 行では nil (= <Enter> 不可)。生存行は session を返す。
      assert.equals('a--b', (list.row_session(buf, 1) or {}).id)
      assert.is_nil(list.row_session(buf, 2))
    end
  )

  it('sessionlist キー (<CR>/q) が付く', function()
    local buf = list.render_sessionlist {}
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      lhs[m.lhs] = true
    end
    assert.is_true(lhs['<CR>'])
    assert.is_true(lhs['q'])
  end)
end)
