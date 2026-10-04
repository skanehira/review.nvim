-- handlers/session: セッション開始フロー (専有 tab 3 窓の開通・窓 opts・panel 幅・
-- chrome)、head 解決フロー (switch 提案 y/n・scratch 縮退・diff-review.md「開始」2)、
-- 既存セッション継承と active 排他 (INV-1)。
-- git 注入スタブ (git/cli_spec と同期 on_exit パターン) で開始〜窓張付を同期駆動し、
-- save は paths._set_data_dir 注入の tmpdir へ実ファイルを書いて検証する (INV-4 =
-- ディスク判定)。head 実ファイル窓の経路 (:edit 相当) はディスク実在が前提なので
-- repo を実ファイル付きで用意する。
-- 窓の中身・close / delete・pr worktree・panel・リフレッシュは session_*_spec に分かれ、
-- 共有の開始部品は tests/helpers/session_fixtures.lua に置く。
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
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
local calls_of = sf.calls_of
local panel_row_for = sf.panel_row_for
local focus_panel_file = sf.focus_panel_file
local inject_comment = sf.inject_comment
local use_env = sf.use_env
local RP_HEAD_MATCH = sf.RP_HEAD_MATCH
local RP_HEAD_MISMATCH = sf.RP_HEAD_MISMATCH
local git_ok = sf.git_ok
local showref_ok = sf.showref_ok
local status_clean = sf.status_clean
local start_done = sf.start_done
local DEGRADED_MSG = sf.DEGRADED_MSG

local review_tab = session_env.review_tab
local head_buf_name = session_env.head_buf_name
local base_buf_name = session_env.base_buf_name

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

      assert.same({ __class = 'review.Result', ok = true }, res)
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

      assert.same({ __class = 'review.Result', ok = true }, res)
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

      assert.same({ __class = 'review.Result', ok = true }, res)
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
      assert.same({}, calls_of 'switch')
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
      assert.same({}, calls_of 'status')
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

    assert.same({}, calls_of 'worktree')
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
      assert.same({}, calls_of 'worktree')
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
      assert.same({}, calls_of 'worktree')
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
