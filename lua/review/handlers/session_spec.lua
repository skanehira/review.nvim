-- handlers/session: セッション開始 / 終了 / 削除と active 排他 (INV-1)、専有 tab
-- 3 窓 UI open / panel 操作 / <Tab> <S-Tab> [F ]F / viewed / tab 消滅経路の save
-- トリガ (INV-4)、
-- head 解決フロー、pr worktree の作成・掃除・直列化 (pr-worktree.md)、絞り込み。
-- git 注入スタブ (git/cli_spec と同期 on_exit パターン) で開始〜窓張付を同期駆動し、
-- save は paths._set_data_dir 注入の tmpdir へ実ファイルを書いて検証する (INV-4 =
-- ディスク判定)。head 実ファイル窓の経路 (:edit 相当) はディスク実在が前提なので
-- repo を実ファイル付きで用意する (旧 unified 自发描画からの設計変更、diff-review.md)。
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_scratchwin = require 'review.ui.scratchwin'
local ui_windows = require 'review.ui.windows'
local session_env = require 'helpers.session_env'
local sf = require 'helpers.session_fixtures'

local SLUG = sf.SLUG
local SIDEBAR_NAME = sf.SIDEBAR_NAME
local RAW_DIFF_A_B = sf.RAW_DIFF_A_B
local state = sf.state
local install_git = sf.install_git
local top_ok = sf.top_ok
local diff_ok = sf.diff_ok
local load_saved = sf.load_saved
local json_path = sf.json_path
local existing_stub = sf.existing_stub
local wt_path = sf.wt_path
local has_call = sf.has_call
local panel_row_for = sf.panel_row_for
local focus_panel_file = sf.focus_panel_file
local inject_comment = sf.inject_comment
local inject_outdated = sf.inject_outdated
local use_env = sf.use_env
local RP_HEAD_MATCH = sf.RP_HEAD_MATCH
local RP_HEAD_MISMATCH = sf.RP_HEAD_MISMATCH
local git_ok = sf.git_ok
local showref_ok = sf.showref_ok
local status_clean = sf.status_clean
local start_done = sf.start_done
local DEGRADED_MSG = sf.DEGRADED_MSG

-- c.lua 削除 + bin.dat binary を含む差分 (窓張り分けの分岐テスト用)。
local RAW_DIFF_DEL_BIN = table.concat({
  'diff --git a/bin.dat b/bin.dat',
  'index 111..222 100644',
  'Binary files a/bin.dat and b/bin.dat differ',
  'diff --git a/c.lua b/c.lua',
  'deleted file mode 100644',
  'index 333..000',
  '--- a/c.lua',
  '+++ /dev/null',
  '@@ -1,2 +0,0 @@',
  '-line1',
  '-line2',
  '',
}, '\n')

-- rename (R) 差分 (実 git 2.x の rename from/to 形。base 窓 old_path 充填の pin 用)。
local RAW_DIFF_RENAME = table.concat({
  'diff --git a/old-name.txt b/new-name.txt',
  'similarity index 80%',
  'rename from old-name.txt',
  'rename to new-name.txt',
  'index 1111111..2222222 100644',
  '--- a/old-name.txt',
  '+++ b/new-name.txt',
  '@@ -1,3 +1,3 @@',
  ' x1',
  '-x2',
  '+changed2',
  ' x3',
  '',
}, '\n')

local function has_worktree_call()
  for _, cmd in ipairs(state.git_calls) do
    if cmd[2] == 'worktree' then
      return true
    end
  end
  return false
end

local review_tab = session_env.review_tab
local head_buf_name = session_env.head_buf_name
local base_buf_name = session_env.base_buf_name

local function inject_comment_at(line, body)
  inject_comment(body, 'a.lua', line)
end

local showref_miss = function()
  return { code = 1, stdout = '', stderr = '' }
end
local status_dirty = function()
  return { code = 0, stdout = ' M a.lua\n', stderr = '' }
end

describe('session.start 開始フロー (専有 tab 3 窓)', function()
  use_env()

  it(
    'diff -> save -> 専有 tab 3 窓 (panel 左 / base / head 実ファイル) -> active 化',
    function()
      local res = start_done('main', 'feature')

      assert.equals(true, res.ok)
      assert.same({ 'git', 'rev-parse', '--show-toplevel' }, state.git_calls[1])
      -- head==HEAD 一致 (通常経路) は作業ツリー基準の単引数形
      assert.same({ 'git', 'rev-parse', '--verify', 'feature' }, state.git_calls[2])
      assert.same({ 'git', 'rev-parse', '--verify', 'HEAD' }, state.git_calls[3])
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[4])
      -- 一覧先頭ファイルの open_file = 移動系の唯一経路 (base = git show 充填)
      assert.same({ 'git', 'show', 'main:a.lua' }, state.git_calls[5])
      assert.equals(state.repo, state.git_opts[5].cwd)

      assert.same({
        version = 1,
        id = SLUG,
        repo = state.repo,
        mode = 'branch',
        base = 'main',
        head = 'feature',
        pr = vim.NIL,
        worktree = vim.NIL,
        status = 'open',
        -- files entry は一覧解決時 viewed=false で作られるが、open 効果では付かない
        -- (レビュー完了マーク = panel の x トグルのみ / diff-review「file panel」)
        files = { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
        comments = {},
        created_at = 4321,
        updated_at = 4321,
      }, load_saved())

      local tab = review_tab()
      assert.is_true(tab ~= nil and vim.api.nvim_tabpage_is_valid(tab))
      assert.is_not.equals(state.tab, tab, 'レビューは専有 tabpage で開く')
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(state.tab), 'ユーザー窓を触らない')
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(tab))

      local pos = function(w)
        return vim.fn.win_screenpos(w)[2]
      end
      assert.is_true(pos(ui_windows.win 'panel') < pos(ui_windows.win 'base'))
      assert.is_true(pos(ui_windows.win 'base') < pos(ui_windows.win 'head'))

      assert.equals(state.repo .. '/a.lua', head_buf_name())
      assert.equals('review://base/' .. SLUG .. '/a.lua', base_buf_name())
      -- base 窓 = git show <base>:<path> 充填・filetype detect (窓の中身表)
      local base_buf = vim.fn.bufnr('review://base/' .. SLUG .. '/a.lua')
      assert.same({ 'line1', 'line2' }, vim.api.nvim_buf_get_lines(base_buf, 0, -1, false))
      assert.equals('lua', vim.bo[base_buf].filetype)
      -- head 実ファイル窓 = 編集可
      local hw = ui_windows.win 'head'
      assert.equals(true, vim.bo[vim.api.nvim_win_get_buf(hw)].modifiable)
      -- 開通 focus は file panel (カーソルはファイルパネルのまま。diff 窓へは移動系・
      -- 標準の窓移動で移る)
      assert.equals(ui_windows.win 'panel', vim.api.nvim_get_current_win())

      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      assert.not_equals(-1, sb)
      -- 開始 open ではマークを付けない (開いただけの行は素のまま)
      assert.same({
        'Changes (2)',
        'Showing changes for: main..working tree',
        'M a.lua +1 -0',
        'A b.lua +1 -0',
        '',
        'Reviewed (0)',
      }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
      assert.equals(0, #state.notifications)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    '開通時にレビュー tab を repo へ tcd する (ユーザー tab には漏れない)',
    function()
      start_done('main', 'feature')
      assert.equals(state.repo, vim.fn.getcwd(-1, 0))
      vim.api.nvim_set_current_tabpage(state.tab)
      assert.equals(state.cwd0, vim.fn.getcwd(-1, 0))
    end
  )

  it('head/base 窓の opts (窓 diff / scrollbind / cursorbind / fold / wrap)', function()
    start_done('main', 'feature')
    for _, role in ipairs { 'base', 'head' } do
      local w = ui_windows.win(role)
      assert.equals(true, vim.wo[w].diff)
      assert.equals(true, vim.wo[w].scrollbind)
      assert.equals(true, vim.wo[w].cursorbind)
      assert.equals('diff', vim.wo[w].foldmethod)
      assert.equals(true, vim.wo[w].wrap)
    end
  end)

  it('panel 窓幅は config.panel_width (既定 35) + winfixwidth', function()
    start_done('main', 'feature')
    local pw = ui_windows.win 'panel'
    assert.equals(35, vim.api.nvim_win_get_width(pw))
    assert.equals(true, vim.wo[pw].winfixwidth)
  end)

  it('splitright が false でも panel 左 / base / head 右', function()
    vim.o.splitright = false
    start_done('main', 'feature')
    local pos = function(w)
      return vim.fn.win_screenpos(w)[2]
    end
    assert.is_true(pos(ui_windows.win 'panel') < pos(ui_windows.win 'base'))
    assert.is_true(pos(ui_windows.win 'base') < pos(ui_windows.win 'head'))
  end)

  it('splitright が true でも panel 左 / base / head 右', function()
    vim.o.splitright = true
    start_done('main', 'feature')
    local pos = function(w)
      return vim.fn.win_screenpos(w)[2]
    end
    assert.is_true(pos(ui_windows.win 'panel') < pos(ui_windows.win 'base'))
    assert.is_true(pos(ui_windows.win 'base') < pos(ui_windows.win 'head'))
  end)

  it(
    '開通時に chrome が効く (global winbar 式 / 窓 number off / w:review_winbar)',
    function()
      vim.o.winbar = ''
      vim.o.number = true -- レビュー開始直前まで番号表示が有効な環境から開始する
      start_done('main', 'feature')
      local hw, bw, pw = ui_windows.win 'head', ui_windows.win 'base', ui_windows.win 'panel'
      assert.equals('main..feature · a.lua · +1 -0 · 0 comments', vim.w[hw].review_winbar)
      assert.equals('base · a.lua (git show)', vim.w[bw].review_winbar)
      assert.equals('main..feature · 2 files · 0 comments', vim.w[pw].review_winbar)
      assert.equals('%{get(w:,"review_winbar","")}', vim.o.winbar)
      -- b: 変数は実ファイル窓経由でユーザー窓へ漏れるため使わない (chrome 決定)
      assert.is_nil(vim.b[vim.fn.bufnr(SIDEBAR_NAME)].review_winbar)
      assert.equals(false, vim.api.nvim_get_option_value('number', { win = hw }))
      assert.equals(false, vim.api.nvim_get_option_value('number', { win = pw }))
      -- ユーザー tab の窓は number のまま = 窓ローカル操作の保証
      vim.api.nvim_set_current_tabpage(state.tab)
      assert.equals(
        true,
        vim.api.nvim_get_option_value(
          'number',
          { win = vim.api.nvim_tabpage_list_wins(state.tab)[1] }
        )
      )
      vim.o.winbar = ''
    end
  )

  it(
    'ref 解決不能 (diff exit 128) は WARN 通知で UI を開かず save もしない',
    function()
      install_git {
        top_ok,
        -- rev-parse <head> 失敗 (短絡) -> 縮退 2 引数形の diff 本体が E_REF を出す
        function()
          return { code = 128, stdout = '', stderr = "fatal: bad revision 'nope'\n" }
        end,
        function()
          -- 実 git と同じ shape (fatal 主行 + usage 続き) で翻訳経路を通す
          return {
            code = 128,
            stdout = '',
            stderr = "fatal: bad revision 'nope'\nusage: git diff [<options>]\n",
          }
        end,
      }
      -- git を伴う失敗は結果型では返さず notify で返す (DESIGN.md「API 一覧」非同期契約)。
      session_handler.start { base = 'main', head = 'nope' }

      -- 存在しない ref に switch 提案も縮退 INFO も出さない (提案対象は解決可能な
      -- ローカルブランチだけ — INV-3)。rev-parse <head> 失敗で short-circuit ->
      -- 縮退 2 引数形の diff 本体が E_REF を出す。
      assert.same({ 'git', 'rev-parse', '--verify', 'nope' }, state.git_calls[2])
      assert.same({ 'git', 'diff', 'main', 'nope' }, state.git_calls[3])
      assert.equals(0, #state.inputs)
      -- 生 stderr 丸出しでなく「名前 + 次の行動」を伝える (UX review F4)
      assert.same({
        msg = 'review.nvim: cannot resolve the reviewed ref: '
          .. '"nope". specify an existing branch/commit '
          .. '(base/head args of start are <Tab>-completable)',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.not_equals(nil, state.notifications[1].msg:find('"nope"', 1, true))
      assert.equals(1, #state.notifications)
      assert.is_nil(load_saved())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.is_nil(session_handler.active())
    end
  )

  it(
    '差分 0 ファイルは「No changes」通知で開始しない (エラーではない)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok ''
        end,
      }
      local res = session_handler.start { base = 'main', head = 'feature' }

      assert.equals(true, res.ok)
      assert.same({
        msg = 'review.nvim: no changes (main..feature): nothing to review',
        level = vim.log.levels.INFO,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.is_nil(session_handler.active())
    end
  )

  it(
    'head 省略は rev-parse --abbrev-ref HEAD を自動採用・保存する (入力 UI を出さない)',
    function()
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = 'feature\n', stderr = '' }
        end,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      local res = session_handler.start { base = 'main' }

      assert.equals(true, res.ok)
      assert.same({ 'git', 'rev-parse', '--abbrev-ref', 'HEAD' }, state.git_calls[2])
      assert.equals('feature', load_saved().head)
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[5])
      assert.equals(0, #state.inputs)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'detached HEAD では head に literal "HEAD" を保存して通常経路で開始する',
    function()
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = 'HEAD\n', stderr = '' }
        end,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main' }

      assert.equals('HEAD', load_saved('main--HEAD').head)
      assert.equals('main--HEAD', session_handler.active().id)
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[5])
      assert.equals(0, #state.inputs)
    end
  )

  it('repo 外 (top 解決失敗) は WARN で開始しない', function()
    install_git {
      function()
        return { code = 128, stdout = '', stderr = 'fatal: not a git repository\n' }
      end,
    }
    session_handler.start { base = 'main', head = 'feature' }

    assert.same(1, #state.notifications)
    assert.equals(vim.log.levels.WARN, state.notifications[1].level)
    assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
  end)
end)

-- ---------------------------------------------------------------------------
-- head / base 窓の中身 (diff-review 表)。scratch 縮退 / 削除 / binary の張り分け。
-- ---------------------------------------------------------------------------

describe('head / base 窓の中身分岐 (窓張り分け表)', function()
  use_env()

  it(
    'scratch 縮退 (switch 拒否): 両窓 scratch + head 窓は git show <head>:<path> 充填',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals('review://base/' .. SLUG .. '/a.lua', base_buf_name())
      assert.equals('review://head/' .. SLUG .. '/a.lua', head_buf_name())
      local head_buf = vim.fn.bufnr('review://head/' .. SLUG .. '/a.lua')
      assert.same({ 'git', 'show', 'feature:a.lua' }, state.git_calls[8])
      assert.equals(state.repo, state.git_opts[8].cwd)
      assert.same({ 'base content' }, vim.api.nvim_buf_get_lines(head_buf, 0, -1, false))
      assert.equals('lua', vim.bo[head_buf].filetype)
      assert.equals('hide', vim.bo[head_buf].bufhidden)
    end
  )

  it(
    '削除ファイル: head 窓は告知 scratch + 両窓 diffoff、base 窓は git show',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }

      -- 一覧先頭 = bin.dat (パス昇順) -> <Tab> で c.lua へ
      assert.equals('review://binary/' .. SLUG .. '/bin.dat', head_buf_name())
      session_handler.next_file() -- c.lua

      assert.equals('review://deleted/' .. SLUG .. '/c.lua', head_buf_name())
      assert.equals('review://base/' .. SLUG .. '/c.lua', base_buf_name())
      local head_buf = vim.fn.bufnr('review://deleted/' .. SLUG .. '/c.lua')
      local lines = vim.api.nvim_buf_get_lines(head_buf, 0, -1, false)
      assert.equals(1, #lines)
      assert.is_true(lines[1]:find('deleted', 1, true) ~= nil)
      -- 削除は告知ペア (head 告知 1 行 / base 旧内容) なので両窓で窓 diff を抜ける
      -- (相手のいない diff ペアを作らない — issue #38)
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      assert.equals(false, vim.wo[ui_windows.win 'base'].diff)
      -- git show 充填は base 窓のみ (head 実ファイル編集事故を作らない)
      assert.is_true(has_call 'git show main:c.lua')
      assert.is_false(has_call 'git show feature:c.lua')
    end
  )

  it(
    'binary: base/head 同一の告知 scratch を共有し両窓 diffoff・git show 0 件',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }

      local name = 'review://binary/' .. SLUG .. '/bin.dat'
      assert.equals(name, head_buf_name())
      assert.equals(name, base_buf_name())
      local buf = vim.fn.bufnr(name)
      assert.equals(2, #vim.fn.win_findbuf(buf))
      assert.same({ 'Binary files differ' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.equals(false, vim.wo[ui_windows.win 'base'].diff)
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      -- 窓 diff に参加しない告知窓なので git show を呼ばない
      assert.is_false(has_call 'git show')
    end
  )

  it(
    '追加ファイル (A): base 窓を閉じ head だけの 2 窓表示 (git show を呼ばない)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      session_handler.next_file() -- b.lua (A)

      assert.is_nil(ui_windows.win 'base')
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(review_tab()))
      assert.is_false(has_call 'git show main:b.lua')
      -- 陰性対照: M の a.lua へ戻ると base 窓が再建され 3 窓ペアに復帰する
      session_handler.prev_file()
      assert.equals('review://base/' .. SLUG .. '/a.lua', base_buf_name())
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(review_tab()))
    end
  )

  it(
    '追加ファイル (A): 窓 diff を張らず head winbar に new file マークを出す (base 窓なし)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      session_handler.next_file() -- b.lua (A)

      assert.is_nil(ui_windows.win 'base')
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      -- 追加 (A) は base が存在しない = 窓 diff に意味がないので base 窓を閉じる
      -- (全行 DiffAdd の塗りつぶしを作らない。M ファイルの窓 diff 有効は別 test が陰性対照)
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      -- head winbar は既定要素 (+a -d / N comments) を保ったまま末尾に種別マーク
      assert.equals(
        'main..feature · b.lua · +1 -0 · 0 comments · new file',
        vim.w[ui_windows.win 'head'].review_winbar
      )
    end
  )

  it(
    'scratch 縮退 + 追加ファイル (A): base 窓を閉じ head は review://head scratch を全幅表示',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'
      session_handler.start { base = 'main', head = 'feature' }
      session_handler.next_file() -- b.lua (A)

      assert.is_nil(ui_windows.win 'base')
      assert.equals('review://head/' .. SLUG .. '/b.lua', head_buf_name())
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(review_tab()))
      -- 縮退経路でも追加 (A) は base 窓なし = head は窓 diff から退避のまま
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
    end
  )

  it(
    '追加ファイル (A): hide で残った同名 base scratch は display されない (base 窓を開かない)',
    function()
      -- M として開いた review tab を :tabclose で閉じると base scratch は hide の
      -- まま残る (on_review_tab_closed「scratch buffer は hide 状態で残る」)。
      -- 現行契約は A で base 窓を開かないため、旧内容の残留は表示に現れない
      -- (窓が無い = base scratch を再利用しない)。
      local leftover = ui_scratchwin.buffer { kind = 'base', session_id = SLUG, path = 'b.lua' }
      ui_scratchwin.set_content(leftover, { 'old base content' })

      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      session_handler.next_file() -- b.lua (A)

      assert.is_nil(ui_windows.win 'base')
      -- 陽性対照: 残骸バッファ自体は存在するが、どの窓にも表示されない
      assert.not_equals(-1, vim.fn.bufnr('review://base/' .. SLUG .. '/b.lua'))
      assert.equals(0, #vim.fn.win_findbuf(leftover))
    end
  )

  it(
    'rename (R): base 窓は <base>:<旧パス> の git show 充填 (old_path 充填の張り分け)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_RENAME)
        end,
        function()
          return { code = 0, stdout = 'old content\n', stderr = '' }
        end, -- git show main:old-name.txt
      }

      session_handler.start { base = 'main', head = 'feature' }

      -- 新パスでなく旧パスを引数に取る (diff-review「head / base 窓の中身」rename 行)
      assert.same({ 'git', 'show', 'main:old-name.txt' }, state.git_calls[5])
      assert.equals(state.repo, state.git_opts[5].cwd)
      local base_buf = vim.fn.bufnr('review://base/' .. SLUG .. '/new-name.txt')
      assert.not_equals(-1, base_buf)
      assert.same({ 'old content' }, vim.api.nvim_buf_get_lines(base_buf, 0, -1, false))
    end
  )

  it(
    'rename で旧パスが base に無い (git show 失敗): base 窓は同名 scratch 空 (0 行)。設計エッジの追認形',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_RENAME)
        end,
        function()
          return {
            code = 128,
            stdout = '',
            stderr = "fatal: path 'old-name.txt' does not exist in 'main'\n",
          }
        end, -- 旧パス自体が新規 = show 失敗
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.same({ 'git', 'show', 'main:old-name.txt' }, state.git_calls[5])
      -- review://null など別名の空 scratch に倒れず、変更ファイルと同じ review://base 名
      assert.equals('review://base/' .. SLUG .. '/new-name.txt', base_buf_name())
      local lines = vim.api.nvim_buf_get_lines(
        vim.fn.bufnr('review://base/' .. SLUG .. '/new-name.txt'),
        0,
        -1,
        false
      )
      -- 空の観測形は 0 行 or 1 個の空行 (追加ファイル側と同規約)
      assert.is_true(
        #lines == 0 or (#lines == 1 and lines[1] == ''),
        'git show 失敗の rename base に内容が残った: ' .. vim.inspect(lines)
      )
    end
  )

  -- 再利用分岐 (diff-review「head / base 窓の中身» «既にユーザーが開いていれば
  -- 同一バッファを再利用») でも_review キーの張込は必須 (head 窓で c/e/d/y/i/o/q が
  -- 効かないと開始導線が壊れる)。b.lua (未既在 = bufadd 生成側) と対で張込を pin。
  local function gate_installed(buf)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if
        m.lhs == 'c'
        and type(m.rhs) == 'string'
        and m.rhs:find('review.ui.keygate', 1, true) ~= nil
      then
        return true
      end
    end
    return false
  end

  it(
    '開始前に :edit 済みの実ファイル: head 窓で再利用され、再利用側にもレビューキーが張られる',
    function()
      vim.cmd('edit ' .. vim.fn.fnameescape(state.repo .. '/a.lua'))
      start_done('main', 'feature')

      local reused = vim.fn.bufnr(state.repo .. '/a.lua')
      assert.equals(
        reused,
        vim.api.nvim_win_get_buf(ui_windows.win 'head'),
        '既在の実ファイル buf が head 窓で再利用される (窓の中身表)'
      )
      assert.is_true(
        gate_installed(reused),
        '再利用分岐でレビューキーが張られていない (c が head 窓で発火しない)'
      )

      -- 対照: 未既在の b.lua (bufadd 側) も同一の open_file 導線で張られている
      session_handler.next_file()
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.is_true(
        gate_installed(vim.api.nvim_win_get_buf(ui_windows.win 'head')),
        '対照の b.lua にもキーが無く、比較自体が壊れている'
      )
    end
  )

  it(
    '復元時 差分まるごと消滅 + outdated comments: 3 窓を開き「No changes」placeholder に集約',
    function()
      local existing = existing_stub {
        status = 'open',
        files = { ['a.lua'] = { viewed = true } },
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'ghost',
            anchor = { before = vim.NIL, line = 'gone', after = vim.NIL },
            state = 'outdated',
            created_at = 1,
          },
        },
      }
      install_git { top_ok }
      session_handler.resume_into(existing, {}, vim.NIL, false)

      assert.is_true(review_tab() ~= nil)
      local ph = 'review://base/' .. SLUG .. '/(no-changes)'
      assert.equals(ph, base_buf_name())
      assert.equals(ph, head_buf_name())
      local head_buf = vim.fn.bufnr(ph)
      assert.same({ 'No changes' }, vim.api.nvim_buf_get_lines(head_buf, 0, -1, false))

      local ns = vim.api.nvim_get_namespaces().review_comment
      local above = nil
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })) do
        if m[4].virt_lines_above then
          above = m
        end
      end
      assert.is_not_nil(above, 'placeholder の outdated 集約 mark が無い')
      -- 集約は箱で描かれ、見出しは箱 1 行目の内容行。見出しは内側幅で折り返し
      -- されうる (placeholder 窓が狭いと 2 行以上) ので、罫線行と本文行を飛ばし
      -- て警告色 chunk (見出し文言の piece) を連結して完全一致を見る。
      -- chunk[1] が table の形も吸収する
      local function chunk_text(chunk)
        return type(chunk[1]) == 'table' and chunk[1][1] or chunk[1]
      end
      local head_pieces = {}
      for _, line in ipairs(above[4].virt_lines or {}) do
        local row = {}
        for _, chunk in ipairs(line) do
          row[#row + 1] = chunk_text(chunk)
        end
        row = table.concat(row)
        if
          row:find('┌', 1, true) == nil
          and row:find('├', 1, true) == nil
          and row:find('└', 1, true) == nil
        then
          -- 見出し以降はコメント側 (メタデータ行 `  [c1]` (警告色) → 本文 'ghost')。
          -- どちらかで打ち切る (メタデータ行も警告色なので混入させない)
          if row:find('ghost', 1, true) ~= nil or row:find('[c1]', 1, true) ~= nil then
            break
          end
          for _, chunk in ipairs(line) do
            if chunk[2] == 'ReviewCommentOutdated' then
              head_pieces[#head_pieces + 1] = chunk_text(chunk)
            end
          end
        end
      end
      assert.equals(' 1 outdated (excluded from prompt)', table.concat(head_pieces))
    end
  )

  it(
    '差分消滅開通でも panel 一覧は diff 由来 0 件・files map に消失ファイルを入れない',
    function()
      local existing = existing_stub {
        status = 'open',
        files = { ['a.lua'] = { viewed = true } },
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'ghost',
            anchor = { before = vim.NIL, line = 'gone', after = vim.NIL },
            state = 'outdated',
            created_at = 1,
          },
        },
      }
      install_git { top_ok }
      session_handler.resume_into(existing, {}, vim.NIL, false)

      -- panel 空一覧 (persistence-restore「files=0 の開通は panel 空一覧」)
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      assert.same({ '' }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
      -- スキーマ: files = 差分に出る全ファイル (消失ファイルの合成行を入れない)
      assert.same({}, load_saved().files)
    end
  )
end)

-- ---------------------------------------------------------------------------
-- panel winbar の outdated 集約先なし ⚠N (diff-review「窓装飾」/ persistence-restore
-- 「anchor 検証」— head 窓さえない outdated の可視化)
-- ---------------------------------------------------------------------------

describe('panel winbar ⚠N (集約先 head 窓の無い outdated)', function()
  use_env()

  it(
    'binary 告知と差分消失ファイルの outdated を panel winbar 末尾 ⚠N に数える',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      inject_outdated('on binary notice', 'bin.dat')
      inject_outdated('on vanished file', 'gone.lua')

      local pw = ui_windows.win 'panel'
      assert.equals('main..feature · 2 files · 2 comments · ⚠2', vim.w[pw].review_winbar)
    end
  )

  it(
    'head 実窓がある outdated は ⚠N に入れず、head バッファ内の id 接頭辞を warning 色にする',
    function()
      start_done('main', 'feature')
      inject_comment 'resolvable thread'
      local sess = session_handler.active()
      sess.comments[1].state = 'outdated'
      session_handler.commit_comment_change()

      -- ⚠N 対象ではない (head 窓に集約先がある)
      local pw = ui_windows.win 'panel'
      assert.equals('main..feature · 2 files · 1 comment', vim.w[pw].review_winbar)
      -- 件数に ⚠ を付けず、本文先頭の id 接頭辞だけ warning 色にする
      local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
      local ns = vim.api.nvim_get_namespaces().review_comment
      local found = nil
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })) do
        local vt = ''
        for _, chunk in ipairs(m[4].virt_text or {}) do
          vt = vt .. (type(chunk[1]) == 'table' and chunk[1][1] or chunk[1])
        end
        if vt == ' \u{EA6B} 1' then
          found = m
        end
      end
      assert.is_not_nil(found, 'outdated 混在 mark が無い')
      assert.equals('ReviewCommentOutdated', found[4].virt_lines[2][2][2])
      assert.equals('ReviewCommentBorder', found[4].virt_lines[2][1][2])
    end
  )
end)

-- ---------------------------------------------------------------------------
-- コメント箱幅のリサイズ追従 (diff-review「コメント表示」。箱幅は apply 時点の
-- head 窓のテキスト幅で固定されるため、WinResized / VimResized で再 apply する。
-- headless では set_width が autocmd を発火しない実測があるため exec_autocmds で
-- 経路を駆動し、実発火は tmux 実測で確認する)
-- ---------------------------------------------------------------------------

describe('コメント箱幅のリサイズ追従 (WinResized / VimResized)', function()
  use_env()

  -- スレッド mark (virt_text) の箱行の最大表示幅
  local function box_max_width()
    local hw = ui_windows.win 'head'
    local buf = vim.api.nvim_win_get_buf(hw)
    local ns = vim.api.nvim_get_namespaces().review_comment
    local maxw = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].virt_text ~= nil then
        for _, line in ipairs(m[4].virt_lines or {}) do
          local w = 0
          for _, chunk in ipairs(line) do
            w = w + vim.fn.strdisplaywidth(chunk[1])
          end
          if w > maxw then
            maxw = w
          end
        end
      end
    end
    return maxw
  end

  local function head_text_width()
    local hw = ui_windows.win 'head'
    local info = vim.fn.getwininfo(hw)[1]
    return vim.api.nvim_win_get_width(hw) - info.textoff
  end

  it('窓幅の変化で箱幅が head 窓のテキスト幅に追随する', function()
    start_done('main', 'feature')
    inject_comment(string.rep('x', 60), 'a.lua', 2)

    local w0 = head_text_width()
    local m0 = box_max_width()
    assert.is_true(m0 > 0, '箱が描かれていない')
    assert.is_true(m0 <= w0, '初期箱が head 窓のテキスト幅を超えている')

    -- 広げる: 本文 60 + 罫線の自然幅までは窓幅に応じて伸びる
    vim.api.nvim_win_set_width(ui_windows.win 'head', 70)
    local w1 = head_text_width()
    assert.is_true(
      w1 > w0,
      'テスト前置: head 窓が広がっていない (レイアウト制約)'
    )
    vim.api.nvim_exec_autocmds('WinResized', {})
    local m1 = box_max_width()
    assert.is_true(m1 <= w1, 'WinResized 後の箱が head 窓のテキスト幅を超えている')
    assert.is_true(m1 > m0, 'WinResized で箱幅が窓幅に追随しない (広げた)')

    -- 狭める
    vim.api.nvim_win_set_width(ui_windows.win 'head', 30)
    local w2 = head_text_width()
    assert.is_true(
      w2 < w1,
      'テスト前置: head 窓が狭まっていない (レイアウト制約)'
    )
    vim.api.nvim_exec_autocmds('VimResized', {})
    local m2 = box_max_width()
    assert.is_true(m2 <= w2, 'VimResized で箱幅が窓幅に追随しない (狭めた)')
  end)
end)

-- ---------------------------------------------------------------------------
-- head 解決フロー (diff-review.md「開始」2 / DESIGN 決定表)
-- ---------------------------------------------------------------------------

local SWITCH_OFFER = 'review.nvim: head feature is a different commit than the current checkout. '
  .. 'switch to feature with git switch and review? [y/N]: '

describe('head 解決フロー (branch: diff-review「開始」2)', function()
  use_env()

  it(
    'rev-parse <head> と HEAD が一致 -> 通常経路 (switch 提案なし・status 照会なし・単引数 diff)',
    function()
      start_done('main', 'feature')

      assert.equals(5, #state.git_calls)
      assert.equals(0, #state.inputs)
      assert.equals(0, #state.notifications)
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[4])
      assert.equals(vim.NIL, load_saved().worktree)
    end
  )

  it(
    '不一致 + ローカルブランチ + clean + 承諾 -> git switch 後に通常経路の単引数 diff (INFO なし)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        git_ok, -- switch ok
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(1, #state.inputs)
      assert.equals(SWITCH_OFFER, state.inputs[1].prompt)
      assert.same({ 'git', 'switch', 'feature' }, state.git_calls[6])
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[7]) -- switch 後 = 作業ツリー基準
      assert.equals(0, #state.notifications)
      assert.equals(SLUG, session_handler.active().id)
      -- switch 後は実ファイル窓 (縮退しない)
      assert.equals(state.repo .. '/a.lua', head_buf_name())
    end
  )

  it(
    '承諾後 switch 失敗 -> WARN + scratch 縮退 INFO、diff は <base> <head> 2 引数形で開始は続く',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return {
            code = 128,
            stdout = '',
            stderr = 'fatal: your local changes would be overwritten by checkout\n',
          }
        end,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.same({
        msg = 'review.nvim: git switch failed; reviewing via a read-only scratch: '
          .. 'fatal: your local changes would be overwritten by checkout',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.same(DEGRADED_MSG, state.notifications[2])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[7])
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'switch 提案を拒否 -> 縮退 INFO + 2 引数 diff で開始 (git switch は一切走らない)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(1, #state.inputs)
      assert.is_false(has_call 'git switch')
      assert.same(DEGRADED_MSG, state.notifications[1])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[6])
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'scratch 縮退時の panel ヘッダは «working tree» でなく保存 head ref 名を出す (DESIGN 決定表)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n' -- switch 拒否 = 縮退

      session_handler.start { base = 'main', head = 'feature' }

      -- 通常経路の «main..作業ツリー» と違い、縮退は見ているのが作業ツリーで
      -- ある保証がないので ref 名 (panel_head_display の degraded 分岐)
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      assert.same({
        'Changes (2)',
        'Showing changes for: main..feature',
        'M a.lua +1 -0',
        'A b.lua +1 -0',
        '',
        'Reviewed (0)',
      }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
    end
  )

  it(
    '不一致 + dirty なworking tree -> 提案を出さない (INV-3) ので縮退 INFO + 2 引数 diff',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_dirty,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(0, #state.inputs)
      assert.same(DEGRADED_MSG, state.notifications[1])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[6])
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    '不一致 + 非ローカルブランチ (show-ref 非ヒット) -> status も見ず提案なしで縮退 (tag/sha 相当)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_miss,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.same(
        { 'git', 'show-ref', '--verify', '--quiet', 'refs/heads/feature' },
        state.git_calls[4]
      )
      assert.is_false(has_call 'git status --porcelain')
      assert.equals(0, #state.inputs)
      assert.same(DEGRADED_MSG, state.notifications[1])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[5])
    end
  )

  it('branch は switch 拒否の縮退でも worktree 起動 0 件・記録 nil', function()
    install_git {
      top_ok,
      RP_HEAD_MISMATCH[1],
      RP_HEAD_MISMATCH[2],
      showref_ok,
      status_clean,
      function()
        return diff_ok(RAW_DIFF_A_B)
      end,
    }
    state.input_answer = 'n'

    session_handler.start { base = 'main', head = 'feature' }

    assert.is_false(has_worktree_call())
    assert.equals(vim.NIL, load_saved().worktree)
  end)

  it(
    'branch はworking tree dirty でも worktree を作らない (縮退は head 解決フローが担う)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_dirty,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(vim.NIL, load_saved().worktree)
      assert.is_false(has_worktree_call())
    end
  )

  it(
    '開始時に created_by_us=true 名残を remove で掃除し、セッション記録は nil になる',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      store.save(existing_stub { worktree = { path = wt, created_by_us = true } })
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        git_ok, -- 掃除: status clean
        git_ok, -- 掃除: remove ok
      }
      state.input_answer = 'y' -- 継承確認

      session_handler.start { base = 'main', head = 'feature' }

      assert.same({ 'git', '-C', wt, 'status', '--porcelain' }, state.git_calls[5])
      assert.same({ 'git', 'worktree', 'remove', wt }, state.git_calls[6])
      assert.equals(vim.NIL, load_saved().worktree)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    '開始時の名残掃除: status clean でも modified バッファがあれば --force 確認を出す (close と同一契約)',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      local file = vim.fs.joinpath(wt, 'a.lua')
      local f = io.open(file, 'w')
      f:write 'line1\nline2\n'
      f:close()
      local buf = vim.fn.bufadd(file)
      vim.fn.bufload(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'USER EDIT' })
      store.save(existing_stub { worktree = { path = wt, created_by_us = true } })
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        git_ok, -- 掃除: status clean (ディスク)
        git_ok, -- 掃除: remove --force ok
      }
      state.input_answer = 'y' -- 継承確認 / force 確認

      session_handler.start { base = 'main', head = 'feature' }

      -- [1] 継承確認 [2] 掃除の --force 確認 (modified バッファを黙って捨てない)
      assert.is_not_nil(state.inputs[2], '名残掃除の force 確認が出ていない')
      assert.equals(
        (
          'review.nvim: worktree %s has uncommitted changes or unsaved buffer edits (%d buffers).'
          .. ' delete and close? (git worktree remove --force '
          .. '— disk and buffer edits are discarded) [y/N]: '
        ):format(wt, 1),
        state.inputs[2].prompt
      )
      assert.same({ 'git', 'worktree', 'remove', '--force', wt }, state.git_calls[6])
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  )

  it(
    'created_by_us=false 名残記録は掃除しない (INV-3: 自前分のみ削除)。remove 起動 0 件',
    function()
      local wt = wt_path()
      store.save(existing_stub { worktree = { path = wt, created_by_us = false } })
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'y' -- 継承確認

      session_handler.start { base = 'main', head = 'feature' }

      -- top / RP x2 / diff / (open) show = 5。worktree 掃除 (status/remove) は 0 件
      assert.equals(5, #state.git_calls)
      assert.is_false(has_worktree_call())
      assert.equals(vim.NIL, load_saved().worktree)
    end
  )
end)

describe('session.start 既存セッション継承と active 排他 (INV-1)', function()
  use_env()

  it(
    '同一 refs 組の保存済みセッションは確認後の継承 (comments / viewed 引き継ぎ)',
    function()
      local existing = existing_stub {
        files = { ['a.lua'] = { viewed = true }, ['b.lua'] = { viewed = false } },
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'keep me',
            anchor = { before = 'line1', line = 'line2', after = vim.NIL },
            state = 'active',
            created_at = 100,
          },
        },
      }
      store.save(existing)

      start_done('main', 'feature')

      local sess = load_saved()
      assert.equals('open', sess.status)
      assert.same(existing.comments, sess.comments)
      assert.equals(true, sess.files['a.lua'].viewed)
      assert.equals(1, #state.inputs) -- 継承確認を 1 回
      assert.equals(
        'review.nvim: the existing session main--feature '
          .. '(main..feature, 1 comments) shares the same refs as this '
          .. 'start '
          .. 'inherit its comments and open? [y/N]: ',
        state.inputs[1].prompt
      )
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      local a_row = panel_row_for('file', 'a.lua')
      assert.equals('M \u{EA6B} a.lua +1 -0', vim.api.nvim_buf_get_lines(sb, 0, -1, false)[a_row])
      -- viewed=true は Reviewed セクションに載る (復元後もセクションが維持される)
      assert.same({
        'Changes (1)',
        'Showing changes for: main..working tree',
        'A b.lua +1 -0',
        '',
        'Reviewed (1)',
        'M \u{EA6B} a.lua +1 -0',
      }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
    end
  )

  it(
    '継承確認を断るとディスクも UI も無変更 (開始も close も走らない)',
    function()
      store.save(existing_stub { status = 'open' })
      local mtime_before = vim.uv.fs_stat(json_path()).mtime
      state.input_answer = 'n'

      start_done('main', 'feature')

      assert.is_nil(session_handler.active())
      assert.same(mtime_before, vim.uv.fs_stat(json_path()).mtime)
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
    end
  )

  it(
    '別 refs 組が active な開始は確認後の save -> close してから新セッション (レビュー tab 張り替え)',
    function()
      start_done('main', 'feature')
      local tab_before = review_tab()

      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'hotfix' }

      assert.equals(1, #state.inputs)
      assert.equals('closed', load_saved('main--feature').status)
      assert.equals('open', load_saved('main--hotfix').status)
      assert.equals('main--hotfix', session_handler.active().id)
      assert.equals(0, vim.fn.bufexists 'review://sidebar/main--feature')
      -- 切替は専有 tab を閉じてから新 tab を開く (レビュー tab を増やさない)
      assert.is_false(vim.api.nvim_tabpage_is_valid(tab_before))
      assert.is_true(review_tab() ~= nil)
    end
  )

  it(
    '別 refs 組が active な開始の確認を断ると既存 active がそのまま残る',
    function()
      start_done('main', 'feature')
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'hotfix' }

      assert.equals(SLUG, session_handler.active().id)
      assert.equals(0, vim.fn.bufexists 'review://sidebar/main--hotfix')
    end
  )

  -- active+同一 refs 保存済みの組合せ (レビューで検出した上書き開始バグの回帰 pin)。
  -- 保存済みがある限り active の有無にかかわらず継承で、上書き開始はできない。
  local function prepare_feature_with_comment_then_switch()
    start_done('main', 'feature')
    inject_comment 'KEEP ME' -- a.lua (save + 表示再構成まで共通経路)
    -- b.lua だけ x でレビュー完了にトグル (a.lua は開いているが未マークのまま)
    focus_panel_file 'b.lua'
    session_handler.toggle_viewed_current()

    install_git {
      top_ok,
      RP_HEAD_MATCH[1],
      RP_HEAD_MATCH[2],
      function()
        return diff_ok(RAW_DIFF_A_B)
      end,
    }
    session_handler.start { base = 'main', head = 'hotfix' } -- 別 refs 組へ切替
    assert.equals('main--hotfix', session_handler.active().id)
    assert.equals('closed', load_saved('main--feature').status)
    state.inputs = {} -- 切替フローの確認は本テストの検証対象から外す
  end

  it(
    'active 下でも同一 refs 組の保存済みは継承 (コメント / viewed 保持、確認 1 回統合)',
    function()
      prepare_feature_with_comment_then_switch()
      local saved = load_saved()
      assert.equals('KEEP ME', saved.comments[1].body) -- 前提: 消さず保存されている

      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(1, #state.inputs) -- close+継承は 1 回の確認に統合
      assert.equals(
        'review.nvim: main--hotfix is the active session. close it and carry on with main--feature?'
          .. ' comments and completion marks are carried over too. [y/N]: ',
        state.inputs[1].prompt
      )
      assert.equals(SLUG, session_handler.active().id)
      local reloaded = load_saved()
      assert.equals('open', reloaded.status)
      assert.same(saved.comments, reloaded.comments) -- 上書きされず comments がそのまま
      assert.equals(true, reloaded.files['b.lua'].viewed)
      assert.equals('closed', load_saved('main--hotfix').status)
      -- 継承後も a.lua は未マーク (開封連動が無い契約の回帰 pin) / b のマークは保持
      local a_row = panel_row_for('file', 'a.lua')
      assert.equals(
        'M \u{EA6B} a.lua +1 -0',
        vim.api.nvim_buf_get_lines(vim.fn.bufnr(SIDEBAR_NAME), 0, -1, false)[a_row]
      )
    end
  )

  it(
    'active 下の同一 refs 組継承確認を断ると active / ディスク無変更',
    function()
      prepare_feature_with_comment_then_switch()
      local mtime_before = vim.uv.fs_stat(json_path()).mtime
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals('main--hotfix', session_handler.active().id)
      assert.same(mtime_before, vim.uv.fs_stat(json_path()).mtime)
      assert.equals(0, vim.fn.bufexists 'review://sidebar/main--feature')
    end
  )

  it(
    '衝突 slug (別 refs 組で同一 slug) は新規作成を拒否し既存を案内する',
    function()
      -- branch_slug の連結は単射でない: ('a--b','c') と ('a','b--c') は同一
      -- slug 'a--b--c' (paths.lua のコメントと同じ衝突)。
      store.save(existing_stub { id = 'a--b--c', base = 'a--b', head = 'c' })

      start_done('a', 'b--c')

      assert.same({
        msg = 'review.nvim: slug a--b--c: an existing session (a--b..c) is registered. '
          .. 'delete it with :Review delete a--b--c',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.is_nil(session_handler.active())
      assert.equals('a--b', store.load(state.repo, 'a--b--c').data.base)
    end
  )
end)

describe('commit_comment_change (INV-4 + extmark 再適用)', function()
  use_env()

  it('save + head extmark 再構成 + head/panel winbar comments 件数', function()
    start_done('main', 'feature')
    inject_comment 'first thread'

    local saved = load_saved()
    assert.equals(1, #saved.comments)
    local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
    local ns = vim.api.nvim_get_namespaces().review_comment
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))

    local hw = ui_windows.win 'head'
    assert.equals('main..feature · a.lua · +1 -0 · 1 comment', vim.w[hw].review_winbar)
    local pw = ui_windows.win 'panel'
    assert.equals('main..feature · 2 files · 1 comment', vim.w[pw].review_winbar)

    -- 2 件目 (同一行 = 同一 group の extmark は併合のまま件数 2)
    inject_comment_at(2, 'second thread')
    assert.equals(2, #load_saved().comments)
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))
    local details = vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })
    local vt = ''
    for _, chunk in ipairs(details[1][4].virt_text or {}) do
      vt = vt .. (type(chunk[1]) == 'table' and chunk[1][1] or chunk[1])
    end
    assert.is_true(vt:find('\u{EA6B} 2', 1, true) ~= nil, vt)
    assert.equals('main..feature · a.lua · +1 -0 · 2 comments', vim.w[hw].review_winbar)
  end)

  it(
    'file panel の行がコメント CRUD 直後に追随する (アイコン表示 -> 消滅)',
    function()
      start_done('main', 'feature')
      local pw = ui_windows.win 'panel'
      local pbuf = vim.api.nvim_win_get_buf(pw)
      local function row_of(path)
        for _, line in ipairs(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)) do
          if line:find(path, 1, true) ~= nil then
            return line
          end
        end
        return nil
      end
      local before = assert(row_of 'a.lua', 'panel に a.lua 行が無い')
      assert.is_nil(
        before:find('\u{EA6B}', 1, true),
        '前提: コメント 0 件でアイコンが出ている'
      )
      inject_comment 'first thread'
      local after = assert(row_of 'a.lua', 'panel に a.lua 行が無い (commit 後)')
      assert.is_true(
        after:find('\u{EA6B}', 1, true) ~= nil,
        'panel 行にコメントアイコンが反映されない'
      )
      -- 削除 (最後の 1 件) でアイコンも消える (同じ render 経路)
      table.remove(session_handler.active().comments, 1)
      session_handler.commit_comment_change()
      local restored = assert(row_of 'a.lua')
      assert.is_nil(
        restored:find('\u{EA6B}', 1, true),
        'panel 行からアイコンが消えない'
      )
    end
  )

  it(
    '告知窓 (binary) を開いている間は save と panel winbar のみ (extmark を張らない)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      inject_comment('on-binary', 'bin.dat', 1) -- file=bin.dat のコメントを注入

      local bin_buf = vim.fn.bufnr('review://binary/' .. SLUG .. '/bin.dat')
      local ns = vim.api.nvim_get_namespaces().review_comment
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(bin_buf, ns, 0, -1, {}))
      assert.equals(
        'main..feature · 2 files · 1 comment',
        vim.w[ui_windows.win 'panel'].review_winbar
      )
      assert.equals(1, #load_saved().comments)
    end
  )

  it(
    'placeholder 窓 (no-changes) でコメントを削除しても残り outdated の集約 extmark が復活する',
    function()
      -- 差分まるごと消滅の既存セッション (outdated 2 件) を復元 -> placeholder に集約
      local existing = existing_stub {
        status = 'open',
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'ghost one',
            anchor = { before = vim.NIL, line = 'gone one', after = vim.NIL },
            state = 'outdated',
            created_at = 1,
          },
          {
            id = 'c2',
            file = 'a.lua',
            line = 3,
            end_line = 3,
            body = 'ghost two',
            anchor = { before = vim.NIL, line = 'gone two', after = vim.NIL },
            state = 'outdated',
            created_at = 2,
          },
        },
      }
      install_git { top_ok }
      session_handler.resume_into(existing, {}, vim.NIL, false)

      local head_buf = vim.fn.bufnr('review://base/' .. SLUG .. '/(no-changes)')
      local ns = vim.api.nvim_get_namespaces().review_comment
      local function mark_texts()
        local out = {}
        local marks = vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })
        for _, m in ipairs(marks) do
          if m[4].virt_lines ~= nil then
            for _, vl in ipairs(m[4].virt_lines) do
              for _, chunk in ipairs(vl) do
                out[#out + 1] = type(chunk[1]) == 'table' and chunk[1][1] or chunk[1]
              end
            end
          end
        end
        return table.concat(out, '\n')
      end
      local function mark_count()
        return #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {})
      end
      assert.equals(1, mark_count(), '前提: 集約 mark が 1 件 (placeholder 開通直後)')
      assert.is_truthy(mark_texts():find('c1', 1, true), mark_texts())

      -- placeholder 窓での削除 (commit_comment_change 経路): clear_tracked 後も
      -- no-changes への再適用で集約が復活する (real / degraded と同一条件)。
      table.remove(session_handler.active().comments, 1)
      session_handler.commit_comment_change()

      assert.equals(1, mark_count(), '削除後に集約 mark が消えたまま復活しない')
      local texts = mark_texts()
      assert.is_truthy(texts:find('c2', 1, true), texts)
      assert.is_falsy(texts:find('c1', 1, true), texts)
    end
  )
end)

-- ---------------------------------------------------------------------------
-- pr worktree (作成判断 / 記録再利用 / 直列化)
-- ---------------------------------------------------------------------------
