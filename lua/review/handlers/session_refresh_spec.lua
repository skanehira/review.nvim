-- handlers/session: 保存時リフレッシュ (diff-review.md「リフレッシュ (未コミット反映契約)」)
-- と、persist 経路のセッション一覧追随。BufWritePost の会員判定・in-flight まとめ・
-- close 中解決の順序は git diff を遅延発火する stub (install_git_deferred_diff) で pin する。
-- 共有の開始部品は tests/helpers/session_fixtures.lua (session_spec と同じ土俵)。
local cli = require 'review.git.cli'
local commentmarks = require 'review.ui.commentmarks'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'
local git_env = require 'helpers.git_env'
local git_stub = require 'helpers.git_stub'
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
local wt_path = sf.wt_path
local focus_panel_file = sf.focus_panel_file
local inject_comment = sf.inject_comment
local use_env = sf.use_env
local OTHER_SHA = sf.OTHER_SHA
local RP_HEAD_MATCH = sf.RP_HEAD_MATCH
local RP_HEAD_MISMATCH = sf.RP_HEAD_MISMATCH
local showref_ok = sf.showref_ok
local status_clean = sf.status_clean
local start_done = sf.start_done
local started_with_worktree = sf.started_with_worktree
local DEGRADED_MSG = sf.DEGRADED_MSG
local gh_api_stub = git_stub.gh_api_stub
local head_buf_name = session_env.head_buf_name

-- 保存後の作業ツリーを模擬する 2 回目の差分: a.lua は +2 増で line2 が行 4 へ
-- 後退 (anchor ±20 補正の対象)。c.lua が新規出現、b.lua は差分から消滅
-- (outdated 化 + map / 一覧から除去 -> winbar ⚠ で可視化)。a.lua の ±は +1 -> +2
-- に動く。
local RAW_DIFF_V2 = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1 +1,4 @@',
  ' line1',
  '+insA',
  '+insB',
  ' line2',
  'diff --git a/c.lua b/c.lua',
  'new file mode 100644',
  'index 0000000..4444444',
  '--- /dev/null',
  '+++ b/c.lua',
  '@@ -0,0 +1 @@',
  '+c1',
  '',
}, '\n')

-- 保存後に a.lua の実バッファが見る内容 (RAW_DIFF_V2 の new 側 = 4 行)。head 窓は
-- 実ファイルなので、単体でも保存後のディスク状態をバッファへ反映して張返を pin する。
local A_SAVED_LINES = { 'line1', 'insA', 'insB', 'line2' }

-- install_git の `git diff` のみ on_exit を遅延発火するスタブ (DESIGN「既知の
-- 制約」: 既定注入スタブは同期なので in-flight まとめ / close 中解決の順序契約
-- は遅延スタブでなければ観測できない)。deferred に応答を 1 呼べる。
local function install_git_deferred_diff(responses)
  state.git_calls = {}
  state.git_opts = {}
  state.deferred = nil
  state.diff_calls = 0
  cli._set_system(function(cmd, opts, on_exit)
    if gh_api_stub(cmd, on_exit) then
      return
    end
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    state.git_opts[idx] = opts
    if cmd[2] == 'diff' then
      state.diff_calls = state.diff_calls + 1
      -- 解決コール内で次の deferred が登録される (追い fetch)。自分の分だけを
      -- 掃除する (後発を nil で潰さない)。
      local wrap
      wrap = function(res)
        on_exit(res)
        if state.deferred == wrap then
          state.deferred = nil
        end
      end
      state.deferred = wrap
      return
    end
    if responses[idx] == nil then
      error('git stub: 想定外の追加実行 ' .. table.concat(cmd, ' '), 0)
    end
    on_exit(responses[idx](cmd, opts))
  end)
  git_env.executable_ok()
end

-- 保存されたセッションファイル実体のバッファ (head 窓が張る実ファイルそのもの。
-- state.repo 配下が auto refresh の会員条件)。BufWritePost は exec_autocmds で
-- 発火させる (headless で :w 実書き込みより決定的。契約の本体は「buffer イベント」)。
local function session_file_buf(path)
  local name = state.repo .. '/' .. path
  local buf = vim.fn.bufnr(name)
  if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

local function fire_buf_write_post(buf)
  vim.api.nvim_exec_autocmds('BufWritePost', { buffer = buf, modeline = false })
end

-- 開始済みセッションにコメントを 2 件植えて save (a.lua は補正対象、
-- b.lua はリフレッシュで痕跡消失 -> outdated 対象)。
local function seed_two_comments()
  session_handler.active().comments = {
    {
      id = 'c1',
      file = 'a.lua',
      line = 2,
      end_line = 2,
      body = 'shift me',
      anchor = { before = 'line1', line = 'line2', after = vim.NIL },
      state = 'active',
      created_at = 100,
    },
    {
      id = 'c2',
      file = 'b.lua',
      line = 1,
      end_line = 1,
      body = 'gone',
      anchor = { before = vim.NIL, line = 'b1', after = vim.NIL },
      state = 'active',
      created_at = 101,
    },
  }
  session_handler.commit_comment_change() -- INV-4 save (リフレッシュ前の基準状態)
end

describe(
  '保存時リフレッシュ (diff-review「リフレッシュ (未コミット反映契約)」)',
  function()
    use_env()

    local function panel_rows()
      return vim.api.nvim_buf_get_lines(vim.fn.bufnr(SIDEBAR_NAME), 0, -1, false)
    end

    local function head_winbar()
      local w = ui_windows.win 'head'
      return w ~= nil and vim.w[w].review_winbar or nil
    end

    local function panel_winbar()
      local w = ui_windows.win 'panel'
      return w ~= nil and vim.w[w].review_winbar or nil
    end

    after_each(function()
      session_handler._set_diffupdate(nil)
      -- 実ファイルバッファは tab と無関係に生きるので明示掃除
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if vim.api.nvim_buf_is_valid(buf) and name:sub(1, #state.repo) == state.repo then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end)

    it(
      'BufWritePost -> git 再取得 -> parse -> anchor 検証 -> save の順 (±カウント・panel・winbar・extmark 再適用)',
      function()
        start_done('main', 'feature')
        seed_two_comments()

        -- 保存後の実ファイルを模擬 (a.lua new 側 4 行 = RAW_DIFF_V2 の内容)。
        local abuf = session_file_buf 'a.lua'
        vim.api.nvim_buf_set_lines(abuf, 0, -1, false, A_SAVED_LINES)

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          -- head commit 比較 (通常経路は一致 = INFO なし)
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(abuf)

        -- 応答キューの呼び出し順が仕様の一部 (DESIGN「development」)。差分再取得は
        -- head 解決と一致する単引数形 (作業ツリー基準)、その後 commit 比較。
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.same({ 'git', 'rev-parse', '--verify', 'feature' }, state.git_calls[2])
        assert.same({ 'git', 'rev-parse', '--verify', 'HEAD' }, state.git_calls[3])
        assert.equals(3, #state.git_calls)
        assert.equals(0, #state.notifications)

        -- 再パース -> anchor 検証 -> save の順序はディスク JSON の補正で観測
        -- (INV-4: 永続化はメモリ状態ではなくディスクで判定)。
        local saved = load_saved()
        assert.same({
          {
            id = 'c1',
            file = 'a.lua',
            line = 4, -- 'line2' が new 側行 4 へ移動、±20 内補正
            end_line = 4,
            body = 'shift me',
            anchor = { before = 'line1', line = 'line2', after = vim.NIL },
            state = 'active',
            created_at = 100,
          },
          {
            id = 'c2',
            file = 'b.lua',
            line = 1, -- outdated でも保存値のまま保持
            end_line = 1,
            body = 'gone',
            anchor = { before = vim.NIL, line = 'b1', after = vim.NIL },
            state = 'outdated',
            created_at = 101,
          },
        }, saved.comments)
        -- 3 窓契約: 再取得で消えた b.lua は files map に合成行を作らない
        -- (一覧も同じ集合。outdated は panel winbar ⚠N で可視化)
        assert.same({
          -- open はマークを変えない (viewed=レビュー完了 = x でのみ付与)
          ['a.lua'] = { viewed = false },
          ['c.lua'] = { viewed = false },
        }, saved.files)

        -- ±カウント・panel 再適用 (a.lua はコメントあり = アイコン付き)
        assert.same({
          'Changes (2)',
          'Showing changes for: main..working tree',
          'M \u{EA6B} a.lua +2 -0',
          'A c.lua +1 -0',
          '',
          'Reviewed (0)',
        }, panel_rows())
        -- winbar: head 窓は窓変数 chrome (w:review_winbar 一本化)
        assert.equals('main..feature · a.lua · +2 -0 · 1 comment', head_winbar())
        -- b.lua outdated (head 窓の解らないファイル) は panel winbar 末尾 ⚠1
        assert.equals('main..feature · 2 files · 2 comments · ⚠1', panel_winbar())

        -- スレッド extmark は補正後行 4 (0-based 3) へ張返 (実ファイル窓の
        -- mark を捨てて session から再構成 — diff-review「コメント表示」)
        local marks = vim.api.nvim_buf_get_extmarks(abuf, commentmarks.ns(), 0, -1, {})
        assert.equals(1, #marks)
        assert.equals(3, marks[1][2])
      end
    )

    it(
      'in-flight 中の保存は dirtyまとめ (再取得 1 本のまま)、完了後の追い fetch は 1 回だけ',
      function()
        start_done('main', 'feature')
        install_git_deferred_diff {
          nil, -- diff #1 (deferred: placeholder)
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
          nil, -- diff #2 (追い fetch: deferred)
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }

        session_handler.refresh() -- #1 発射
        fire_buf_write_post(session_file_buf 'a.lua') -- in-flight 中 -> dirty
        fire_buf_write_post(session_file_buf 'a.lua') -- 2 回目の保存もまとめ

        assert.equals(1, state.diff_calls) -- 多重 fetch しない
        assert.is_true(state.deferred ~= nil)

        state.deferred(diff_ok(RAW_DIFF_V2)) -- #1 解決 -> apply -> dirty -> 追い 1 本

        assert.equals(2, state.diff_calls)
        assert.is_true(state.deferred ~= nil)

        state.deferred(diff_ok(RAW_DIFF_V2)) -- 追い fetch 解決 -> ここで完了

        assert.equals(2, state.diff_calls)
        -- 適用は 1 回まとめの最終状態で完了 (b.lua はコメントのない消失ファイル =
        -- 一覧からも落ちる。補正詳細は BufWritePost 側のテストで pin)。
        assert.same({
          'Changes (2)',
          'Showing changes for: main..working tree',
          'M a.lua +2 -0',
          'A c.lua +1 -0',
          '',
          'Reviewed (0)',
        }, panel_rows())
        assert.equals(0, #state.notifications)
      end
    )

    it(
      '再取得失敗は WARN + 前回 parse 保持 (ディスクも panel も無変更)',
      function()
        start_done('main', 'feature')
        seed_two_comments()
        local before_saved = load_saved()
        local before_sidebar = panel_rows()

        install_git {
          function()
            -- 実 git と同じ shape (fatal 主行 + usage 続き)
            return {
              code = 128,
              stdout = '',
              stderr = "fatal: bad revision 'main'\nusage: git diff [<options>]\n",
            }
          end,
        }
        fire_buf_write_post(session_file_buf 'a.lua')

        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.equals(1, #state.git_calls) -- 失敗後は commit 比較も追い fetch も走らない
        assert.same({
          msg = 'review.nvim: failed to refresh the diff; keeping the current view and comments: '
            .. 'cannot resolve the reviewed ref: "main". specify an existing branch/commit '
            .. '(base/head args of start are <Tab>-completable)',
          level = vim.log.levels.WARN,
        }, state.notifications[1])
        assert.equals(1, #state.notifications)
        assert.same(before_saved, load_saved())
        assert.same(before_sidebar, panel_rows())
      end
    )

    it(
      'セッション外保存と scratch 窓の保存は何もしない (会員実ファイルのみ自動リフレッシュ)',
      function()
        start_done('main', 'feature')
        -- 応答なしのスタブ = 会員外で git が走ればその場で error (検出)。
        install_git {}
        -- base scratch (review://base/…): 実ファイルでない = 会員外
        fire_buf_write_post(vim.fn.bufnr('review://base/' .. SLUG .. '/a.lua'))
        -- セッション外の実ファイル名バッファ (repo 根の外)
        local obuf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(obuf, '/tmp/review-spec-outside/a.lua')
        fire_buf_write_post(obuf)
        assert.equals(0, #state.git_calls)
        assert.equals(0, #state.notifications)
        pcall(vim.api.nvim_buf_delete, obuf, { force = true })

        -- 陽性対照: 会員実ファイルの保存は再取得が走る («会員判定が常に false で
        -- 何も起きない» 壊れ方を通過させない — 無条件 return の空実装は通らない)。
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(session_file_buf 'a.lua')
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.equals(3, #state.git_calls)
      end
    )

    it(
      'close 最中に in-flight が解決しても適用しない (active guard: disk も UI も触らない)',
      function()
        start_done('main', 'feature')
        install_git_deferred_diff { nil }
        session_handler.refresh()
        fire_buf_write_post(session_file_buf 'a.lua') -- dirty も設定されるが無効化対象
        assert.equals(1, state.diff_calls)

        session_handler.close() -- コメント 0 件 = 無確認で閉じる (in-flight/dirty 無効化)
        assert.is_nil(session_handler.active())

        state.deferred(diff_ok(RAW_DIFF_V2)) -- 解決: 対象セッションはもう active でない

        assert.equals(1, state.diff_calls) -- 結果破棄 = 追い fetch も走らない
        assert.equals('closed', load_saved().status)
        assert.same(
          { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
          load_saved().files -- c.lua 再パース結果が書き戻されていない
        )
        assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME)) -- 再描画で窓も復活しない
        assert.equals(0, #state.notifications)
      end
    )

    it(
      '現在の開きファイルが再取得差分から消滅: 窓はそのまま +0 -0 でゼロ化、panel 行は map から落ちる',
      function()
        start_done('main', 'feature') -- 初期開き a.lua
        session_handler.open_file 'b.lua' -- b.lua を実ファイル窓へ張り替え
        -- b.lua は追加 (A) = head winbar の末尾に種別マークが付く (issue #38)
        assert.equals('main..feature · b.lua · +1 -0 · 0 comments · new file', head_winbar())

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(session_file_buf 'b.lua')

        -- 窓の張り替えはしない (head は実ファイル = ユーザーの編集対象)。±カウントは
        -- ゼロ差分として zero clear、一覧と files map からは合成行を作らず除去
        -- (outdated 化はコメントのあるファイル側のテストで pin)。
        assert.equals(state.repo .. '/b.lua', head_buf_name())
        -- リフレッシュは bind しないので base 窓を閉じたまま (A) の窓状態と head 側の
        -- 種別マークが維持される (窓状態と winbar の一貫)
        assert.equals('main..feature · b.lua · +0 -0 · 0 comments · new file', head_winbar())
        assert.same({
          'Changes (2)',
          'Showing changes for: main..working tree',
          'M a.lua +2 -0',
          'A c.lua +1 -0',
          '',
          'Reviewed (0)',
        }, panel_rows())
        assert.same(
          { ['a.lua'] = { viewed = false }, ['c.lua'] = { viewed = false } },
          load_saved().files
        )
      end
    )

    it(
      'リフレッシュの再取得は scratch 縮退セッションで <base> <head> 2 引数形 (開始時解決と一致)',
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
        state.input_answer = 'n' -- switch 提案を拒否 = 縮退解で開始
        session_handler.start { base = 'main', head = 'feature' }

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
        }
        session_handler.refresh()

        assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[1])
        -- 縮退は作業ツリーを見ないので head commit 比較も走らない (1 本だけ)
        assert.equals(1, #state.git_calls)
        assert.same(DEGRADED_MSG, state.notifications[1])
        assert.equals(1, #state.notifications)
      end
    )

    it(
      'リフレッシュの再取得は pr で cwd=worktree の単引数形 (開始時解決と一致・HEAD 比較なし)',
      function()
        started_with_worktree()

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
        }
        session_handler.refresh()

        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.equals(wt_path(), state.git_opts[1].cwd)
        -- PR は worktree を --detach するため HEAD 比較は恒真 (誤発火) -> 呼ばない
        assert.equals(1, #state.git_calls)
        assert.equals(0, #state.notifications)
      end
    )

    it(
      'head と現在の HEAD の commit 違いを INFO 1 回 (処理は続行)、告知後は比較打ち切り',
      function()
        start_done('main', 'feature')

        -- #1: commit 一致 -> INFO なし (比較の 2 rev-parse は走る)
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        session_handler.refresh()
        assert.same({ 'git', 'rev-parse', '--verify', 'feature' }, state.git_calls[2])
        assert.same({ 'git', 'rev-parse', '--verify', 'HEAD' }, state.git_calls[3])
        assert.equals(0, #state.notifications)

        -- #2: head=OTHER / HEAD=SAME -> 不一致 INFO 1 回 + 適用は進む (定義は
        -- base vs 現在のチェックアウトであり処理を止めない)
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          function()
            return { code = 0, stdout = OTHER_SHA .. '\n', stderr = '' }
          end,
          RP_HEAD_MATCH[2],
        }
        session_handler.refresh()
        assert.same({
          msg = 'review.nvim: the head at session start is not the current checkout',
          level = vim.log.levels.INFO,
        }, state.notifications[1])
        assert.equals(1, #state.notifications)
        assert.same({
          'Changes (2)',
          'Showing changes for: main..working tree',
          'M a.lua +2 -0',
          'A c.lua +1 -0',
          '',
          'Reviewed (0)',
        }, panel_rows())

        -- #3: 告知済み -> rev-parse 比較は以後走らない (save ごとに同じ告知を出さ
        -- ない。余剰呼び出しは stub が error で弾く)
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
        }
        session_handler.refresh()
        assert.equals(1, #state.git_calls)
        assert.equals(1, #state.notifications)
      end
    )

    it(
      ':diffupdate はセッション実ファイルの &diff 窓にだけ発火 (head 枠と同一 buf の user 窓。base scratch・セッション外窓は不発火)',
      function()
        local fired = {}
        start_done('main', 'feature')
        session_handler._set_diffupdate(function(win)
          fired[#fired + 1] = vim.api.nvim_win_get_buf(win)
        end)

        -- head 窓の張る実ファイル (&diff) = 発火対象。加えて同一バッファを
        -- &diff で見るユーザー窓 (会員なので同じ buf の窓全てが対象)。
        local abuf = vim.fn.bufnr(state.repo .. '/a.lua')
        vim.api.nvim_set_current_tabpage(state.tab)
        vim.cmd 'vsplit'
        vim.api.nvim_win_set_buf(0, abuf)
        vim.api.nvim_win_set_option(0, 'diff', true)
        -- ユーザー自分の別ツリーの diff 窓 (セッション会員外)
        local obuf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(obuf, '/tmp/review-spec-outside/x.lua')
        vim.cmd 'vsplit'
        vim.api.nvim_win_set_buf(0, obuf)
        vim.api.nvim_win_set_option(0, 'diff', true)

        -- 会員実ファイルのバッファへ BufWritePost -> 再取得適用後に :diffupdate が
        -- 発火するのは会員 &diff 窓だけ (base scratch 窓・会員外窓は不発火、
        -- panel 窓は &diff なし)。
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(abuf)

        -- 2 エントリともセッション実ファイル buf = head 窓とユーザー窓の 2 つ
        -- (会員外の obuf・base scratch が混じらないことの完全一致 assert)。
        assert.same({ abuf, abuf }, fired)

        pcall(vim.api.nvim_buf_delete, obuf, { force = true })
      end
    )
  end
)

-- ---------------------------------------------------------------------------
-- セッション一覧の追随 (persist 1 箇所フック / :Review list)
-- ---------------------------------------------------------------------------
describe('セッション一覧の追随 (persist 経路 / :Review list)', function()
  use_env()

  local list_buf

  -- :Review list の窓を模す: review tab 外 (隔離 tab) の vsplit に一覧を表示。
  -- render は ui/list 直接 (M.open は別の git 応答キューを消費するため)。
  local function open_sessionlist()
    vim.api.nvim_set_current_tabpage(state.tab)
    list_buf = require('review.ui.list').render_sessionlist(store.list(state.repo).data, {
      repo = state.repo,
    })
    vim.cmd 'vsplit'
    vim.api.nvim_win_set_buf(0, list_buf)
  end

  local function session_row()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)) do
      if line:find(SLUG, 1, true) ~= nil then
        return line
      end
    end
    return nil
  end

  -- 一覧の 1 行 (ui/list の行書式)。時刻はローカル + tz で、期待値も同じ os.date で組む。
  local function expected_row(status, comments, updated_at)
    return ('%s  %s  branch  main..feature  %d comments  %s'):format(
      SLUG,
      status,
      comments,
      os.date('%Y-%m-%d %H:%M %Z', updated_at)
    )
  end

  it(
    'x / コメント CRUD / R のあと、開いている一覧の comments 列と更新時刻が追随する',
    function()
      start_done('main', 'feature')
      open_sessionlist()
      assert.equals(expected_row('open', 0, 4321), session_row())

      -- コメント CRUD (commit_comment_change -> persist): comments 列が追随する
      inject_comment 'list follow thread'
      assert.equals(expected_row('open', 1, 4321), session_row())

      -- x (toggle_viewed_current -> persist): 更新時刻列が現在時刻へ追随する
      store._set_now(function()
        return 5000
      end)
      focus_panel_file 'a.lua'
      session_handler.toggle_viewed_current()
      assert.equals(expected_row('open', 1, 5000), session_row())

      -- R (差分再取得 -> apply_refresh -> persist): 件数を維持したまま時刻が追随する
      store._set_now(function()
        return 6000
      end)
      local abuf = session_file_buf 'a.lua'
      install_git {
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
      }
      fire_buf_write_post(abuf)
      assert.equals(expected_row('open', 1, 6000), session_row())
    end
  )

  it('q close のあと、開いている一覧の status 列が closed へ追随する', function()
    start_done('main', 'feature')
    open_sessionlist()
    assert.equals(expected_row('open', 0, 4321), session_row())

    session_handler.close() -- コメント 0 件 = 確認なし

    assert.equals(expected_row('closed', 0, 4321), session_row())
    -- ディスクも closed (INV 判定はメモリでなくディスク)
    assert.equals('closed', load_saved().status)
  end)
end)

-- ---------------------------------------------------------------------------
-- file panel ツリー表示 / view state (issue-17 の handlers 側契約)。
-- 行フォーマットの正誤表そのものは ui/treelist_spec / ui/filepanel_spec (実 FS) が
-- pin するので、ここでは «i トグル・dir 折込・カーソル逆追従・view state が
-- session JSON に載らない» の調停のみを検証する。多段差分スタブ (app/util/*,
-- cmd ファイルと cmd/ dir の同名併存 (置換), z.txt) を実 disk なしで駆動する
-- (head は未実在 = 告知 scratch 経路。panel 契約の検証には不要)。
-- ---------------------------------------------------------------------------
