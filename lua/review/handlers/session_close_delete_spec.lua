-- handlers/session: セッションの終了 (close / tab 消滅) と削除 (delete) の経路。
-- q / :Review close / :tabclose の save トリガ (INV-4 = ディスク判定)、close の
-- worktree 保持、delete の worktree / ref / JSON 掃除と --force 確認・中止条件
-- (pr-worktree.md「worktree の寿命」/ persistence-restore.md)。
-- 共有の開始部品は tests/helpers/session_fixtures.lua (session_spec と同じ土俵)。
local paths = require 'review.store.paths'
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
local install_git_deferred_remove = sf.install_git_deferred_remove
local top_ok = sf.top_ok
local diff_ok = sf.diff_ok
local load_saved = sf.load_saved
local json_path = sf.json_path
local existing_stub = sf.existing_stub
local wt_path = sf.wt_path
local git_fail = sf.git_fail
local inject_comment = sf.inject_comment
local use_env = sf.use_env
local git_ok = sf.git_ok
local start_done = sf.start_done
local started_with_worktree = sf.started_with_worktree
local review_tab = session_env.review_tab
local head_buf_name = session_env.head_buf_name

-- 応答の選択肢を 1 回目順に 1 件ずつ返す入力スタブ (delete+force の 2 確認用)。
local function answer_queue(answers)
  local idx = 0
  vim.ui.input = function(opts, cb)
    idx = idx + 1
    table.insert(state.inputs, opts)
    cb(answers[idx])
  end
end

-- worktree dir を実 dir として用意する (stub の add は dir を作らない — 上の注記)。
-- head 実ファイル窓が worktree 配下の bufadd / bufload 経路を通るよう、開始前に
-- dir とファイルを自前で書き出す (E211 系の検証は実ファイル + loaded バッファ前提)。
local function make_real_worktree()
  local wt = wt_path()
  vim.fn.mkdir(wt, 'p')
  for _, n in ipairs { 'a.lua', 'b.lua' } do
    local f = io.open(vim.fs.joinpath(wt, n), 'w')
    f:write 'line1\nline2\n'
    f:close()
  end
  return wt
end

describe('session.close / session.delete (q 経路 = close と tab 消滅)', function()
  use_env()

  it('active 0 件の close は E_NOT_ACTIVE を同期で返す', function()
    assert.same({
      __class = 'review.Result',
      ok = false,
      error = 'review.nvim: no active session',
      code = 'E_NOT_ACTIVE',
    }, session_handler.close())
  end)

  it(
    'コメント 0 件: 確認なしで閉じ status=closed / レビュー tab 消滅 / extmark 残骸 0',
    function()
      start_done('main', 'feature')
      inject_comment 'first' -- extmark を張っておく (残骸 0 検証のため)
      local tab = review_tab()
      local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
      local ns = vim.api.nvim_get_namespaces().review_comment
      assert.is_true(#vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}) > 0)

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.equals(4321, load_saved().updated_at)
      assert.is_nil(session_handler.active())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.is_false(vim.api.nvim_tabpage_is_valid(tab), 'q = レビュー tab を閉じる')
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))
      -- 実ファイルバッファ (modified を含むユーザー所有物) は消さない
      assert.is_true(vim.api.nvim_buf_is_valid(head_buf))
    end
  )

  it(
    'close は再利用したユーザー既在の実バッファからもレビューキーを除く (残骸 0・バッファ自体は保持)',
    function()
      vim.cmd('edit ' .. vim.fn.fnameescape(state.repo .. '/a.lua'))
      start_done('main', 'feature')
      local reused = vim.api.nvim_win_get_buf(ui_windows.win 'head')
      -- close 直前の正状態 (張込が no-op ならこの assert が落ちる)
      local installed = false
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(reused, 'n')) do
        if
          m.lhs == 'c'
          and type(m.rhs) == 'string'
          and m.rhs:find('review.ui.keygate', 1, true) ~= nil
        then
          installed = true
        end
      end
      assert.is_true(installed, '前提: close 前に張込済みでなければならない')

      session_handler.close()

      assert.is_true(
        vim.api.nvim_buf_is_valid(reused),
        'ユーザー実バッファは消さない'
      )
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(reused, 'n')) do
        assert.is_true(
          type(m.rhs) ~= 'string' or m.rhs:find('review.ui.keygate', 1, true) == nil,
          '残骸: ' .. m.lhs
        )
      end
    end
  )

  it(
    'close_by_key と tabclose の INFO が競合しない (q 経路は tab 消滅 INFO を出さない)',
    function()
      start_done('main', 'feature')
      session_handler.close_by_key()
      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      for _, n in ipairs(state.notifications) do
        assert.is_true(
          n.msg:find('closed the review tab', 1, true) == nil,
          'q 経路で tab 消滅 INFO が出た: ' .. n.msg
        )
      end
    end
  )

  it(
    'コメントありの close は確認を要求する (n なら閉じず / y で status=closed)',
    function()
      start_done('main', 'feature')
      inject_comment 'keep'

      state.input_answer = 'n'
      session_handler.close()
      assert.equals('open', load_saved().status)
      assert.equals(SLUG, session_handler.active().id)
      assert.is_true(review_tab() ~= nil)

      state.input_answer = 'y'
      session_handler.close()
      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
    end
  )

  it(
    'ユーザーが :tabclose で閉じる: active 解除・status=open 維持・save・INFO («開き直し可»)',
    function()
      start_done('main', 'feature')
      inject_comment 'tabclosed-keep'
      local review_t = review_tab()

      vim.api.nvim_set_current_tabpage(review_t)
      vim.cmd 'tabclose!'
      vim.wait(300, function()
        return session_handler.active() == nil
      end)

      assert.is_false(vim.api.nvim_tabpage_is_valid(review_t))
      assert.is_nil(session_handler.active())
      local saved = load_saved()
      assert.equals(
        'open',
        saved.status,
        'tab 消滅を close と解釈しない (status=open 維持)'
      )
      assert.equals(1, #saved.comments) -- save 済み (INV-4 + tab 消滅 save)
      local notify = nil
      for _, n in ipairs(state.notifications) do
        if n.msg:find('closed the review tab', 1, true) ~= nil then
          notify = n
        end
      end
      assert.is_not_nil(notify, 'tab 消滅 INFO が無い')
      assert.equals(vim.log.levels.INFO, notify.level)
      -- extmark 残骸 0 (張った head 実バッファを明示 clear — 開き直しまで残さない)
      local head_buf = vim.fn.bufnr(state.repo .. '/a.lua')
      local ns = vim.api.nvim_get_namespaces().review_comment
      assert.is_true(vim.api.nvim_buf_is_valid(head_buf))
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))
    end
  )

  -- 互換 pin (issue #26): v0.10.0 と stable で TabClosed 発火時点の tab handle
  -- 失効タイミングが違う (0.10.0 は is_valid が true のまま発火する)。両バージョンが
  -- ともに満たすべき振る舞いの 3 点セットを 1 つの test に締める。
  it(
    'tab 消滅 → 掃除完走 + windows.state() nil + session status=open 維持'
      .. ' (0.10.0/stable 互換 pin)',
    function()
      start_done('main', 'feature')
      local review_t = review_tab()

      vim.api.nvim_set_current_tabpage(review_t)
      vim.cmd 'tabclose!'
      vim.wait(300, function()
        return ui_windows.state() == nil and session_handler.active() == nil
      end)

      assert.is_true(
        not vim.tbl_contains(vim.api.nvim_list_tabpages(), review_t),
        'review tab が現存している (消滅していない)'
      )
      assert.is_nil(
        ui_windows.state(),
        'tab 消滅後も windows.state が居残りの版がある'
      )
      assert.is_nil(session_handler.active())
      assert.equals('open', load_saved().status, 'tab 消滅を close と解釈しない')
    end
  )

  it(
    'レビュー tab を閉じたまま :Review start (同一 refs) で開き直せる (placeholder でなく実窓)',
    function()
      start_done('main', 'feature')
      vim.api.nvim_set_current_tabpage(review_tab())
      vim.cmd 'tabclose!'
      vim.wait(300, function()
        return session_handler.active() == nil
      end)
      -- 開き直し = 同一 refs 組の保存済み継承 (confirm y)。git は start 相当を再実行
      start_done('main', 'feature')
      assert.equals(SLUG, session_handler.active().id)
      assert.equals(state.repo .. '/a.lua', head_buf_name())
    end
  )

  it('delete: 確認 -> active 解除 -> JSON ファイル削除', function()
    start_done('main', 'feature')
    install_git { top_ok }
    state.input_answer = 'y'

    session_handler.delete(SLUG)

    assert.is_nil(session_handler.active())
    assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
  end)

  it('delete: 確認を要求する (n では削除しない)', function()
    start_done('main', 'feature')
    install_git { top_ok }
    state.input_answer = 'n'

    session_handler.delete(SLUG)

    assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
    assert.equals(SLUG, session_handler.active().id)
  end)
end)

describe('close の worktree 保持 (セッション終了 / 削除は delete のみ)', function()
  use_env()

  it(
    'worktree があっても close は remove しない (save(closed) + UI 掃除のみ、dir は残る)',
    function()
      started_with_worktree()
      vim.fn.mkdir(wt_path(), 'p')
      install_git {} -- 予期しない git 呼び出しは stub が error

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.equals(0, #state.git_calls, 'close に status / remove が走った (keep が契約)')
      assert.is_true(vim.uv.fs_stat(wt_path()) ~= nil, 'close で worktree dir が消えた')
    end
  )

  it(
    '未コミット変更があっても close は確認なしで閉じる (削除しないので worktree・バッファも残る)',
    function()
      make_real_worktree()
      started_with_worktree()
      local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
      vim.api.nvim_buf_set_lines(head_buf, 1, 2, false, { 'USER EDIT' })
      install_git {}

      session_handler.close()

      assert.equals(0, #state.inputs, 'close に --force 確認は無い (削除しない)')
      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.equals(0, #state.git_calls)
      assert.is_true(vim.api.nvim_buf_is_valid(head_buf))
      assert.equals(true, vim.bo[head_buf].modified) -- 未保存編集も残る
      assert.is_true(vim.uv.fs_stat(wt_path()) ~= nil)
    end
  )

  it(
    'close -> 即 begin (pr) は remove を挟まず既存 worktree を再利用する (二重登録レースの根絶)',
    function()
      started_with_worktree()
      vim.fn.mkdir(wt_path(), 'p')
      install_git {
        function()
          return { code = 0, stdout = 'worktree ' .. wt_path() .. '\n', stderr = '' }
        end, -- worktree list (再利用判定)
        function()
          return diff_ok(RAW_DIFF_A_B)
        end, -- diff
      }
      state.input_answer = 'y'

      session_handler.close_by_key()
      session_handler.begin {
        repo = state.repo,
        id = SLUG,
        mode = 'pr',
        base = 'main',
        head = 'feature',
      }

      for _, c in ipairs(state.git_calls) do
        if c[2] == 'worktree' and (c[3] == 'add' or c[3] == 'remove') then
          error('close->begin で worktree add/remove が走った (再利用が契約)', 0)
        end
      end
      assert.same({ 'git', 'worktree', 'list', '--porcelain' }, state.git_calls[1])
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[2])
      assert.equals('open', load_saved().status)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'close は worktree 配下の実ファイルバッファを破棄しない (dir が残るので E211 は起きない)',
    function()
      local wt = make_real_worktree()
      started_with_worktree()
      local fname = vim.uv.fs_realpath(vim.fs.joinpath(wt, 'a.lua'))
      assert.equals(
        1,
        vim.fn.bufexists(fname),
        '前提: close 前に head 実ファイルバッファがある'
      )
      local user_buf = vim.fn.bufadd(vim.fs.joinpath(wt, 'b.lua'))
      vim.fn.bufload(user_buf)
      install_git {}

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.equals(
        1,
        vim.fn.bufexists(fname),
        'close で worktree 配下のバッファが消えた (dir は残る = keep が契約)'
      )
      assert.equals(1, vim.fn.bufexists(user_buf))
      assert.is_true(vim.uv.fs_stat(wt) ~= nil)
    end
  )

  it('worktree なしセッションの close は git 追加呼び出し 0', function()
    start_done('main', 'feature')
    install_git {}
    session_handler.close()
    assert.equals('closed', load_saved().status)
    assert.equals(0, #state.git_calls)
  end)

  it(
    'INV-3: created_by_us=false 記録のまま close すると worktree に一切触れない',
    function()
      started_with_worktree()
      -- active / disk の記録を非自前へ書き換える (テスト目的の注入)
      local sess = load_saved()
      sess.worktree = { path = wt_path(), created_by_us = false }
      assert.equals(true, store.save(sess).ok)
      session_handler.active().worktree = sess.worktree
      install_git {}

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.same({ path = wt_path(), created_by_us = false }, load_saved().worktree)
      assert.equals(0, #state.git_calls)
    end
  )
end)

describe('delete の worktree / ref 掃除', function()
  use_env()

  it(
    '閉じた作成分残骸 (active なし): status -> remove 掃除 -> 自前 pr ref 削除 -> JSON 削除',
    function()
      vim.fn.mkdir(wt_path 'pr-7', 'p')
      store.save(existing_stub {
        id = 'pr-7',
        mode = 'pr',
        base = 'main',
        head = 'review-nvim/pr-7',
        pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
        worktree = { path = wt_path 'pr-7', created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
        git_ok, -- remove ok
        git_ok, -- update-ref ok
      }
      state.input_answer = 'y'

      session_handler.delete 'pr-7'

      assert.same({ 'git', '-C', wt_path 'pr-7', 'status', '--porcelain' }, state.git_calls[2])
      assert.same({ 'git', 'worktree', 'remove', wt_path 'pr-7' }, state.git_calls[3])
      assert.same({ 'git', 'update-ref', '-d', 'refs/heads/review-nvim/pr-7' }, state.git_calls[4])
      assert.equals(4, #state.git_calls)
      assert.is_true(vim.uv.fs_stat(paths.session_file(state.repo, 'pr-7')) == nil)
    end
  )

  it(
    '閉じたセッションに worktree 記録なし: git は top だけ (branch なので ref 掃除なし)',
    function()
      store.save(existing_stub { pr = vim.NIL })
      install_git { top_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.equals(1, #state.git_calls)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )

  describe('head 窓実バッファの扱い', function()
    it(
      'tabclose 後も head 実ファイルバッファの modified 内容は失われない',
      function()
        start_done('main', 'feature')
        inject_comment 'keep-buffer'
        local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
        vim.api.nvim_buf_set_lines(head_buf, 1, 2, false, { 'USER EDIT' })

        vim.api.nvim_set_current_tabpage(review_tab())
        vim.cmd 'tabclose!'
        vim.wait(300, function()
          return session_handler.active() == nil
        end)

        assert.is_true(vim.api.nvim_buf_is_valid(head_buf))
        assert.equals(true, vim.bo[head_buf].modified)
        assert.same({ 'line1', 'USER EDIT' }, vim.api.nvim_buf_get_lines(head_buf, 0, -1, false))
      end
    )
  end)

  it(
    'closed 残骸 delete: git status clean でも modified バッファがあれば --force 確認を出す (承認で remove --force)',
    function()
      local wt = wt_path 'pr-7'
      vim.fn.mkdir(wt, 'p')
      local file = vim.fs.joinpath(wt, 'a.lua')
      local f = io.open(file, 'w')
      f:write 'line1\nline2\n'
      f:close()
      local buf = vim.fn.bufadd(file)
      vim.fn.bufload(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'USER EDIT' })
      store.save(existing_stub {
        id = 'pr-7',
        mode = 'pr',
        base = 'main',
        head = 'review-nvim/pr-7',
        pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
        worktree = { path = wt, created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean (ディスク。バッファ上の編集は現れない)
        git_ok, -- remove --force ok
        git_ok, -- update-ref ok
      }
      state.input_answer = 'y'

      session_handler.delete 'pr-7'

      -- delete 残骸経路も close と同一契約: dirty 判定は git status + modified
      -- バッファ。未保存編集を黙って force wipe しない
      assert.is_not_nil(
        state.inputs[2],
        'force 確認が出ていない (未保存編集の無告知破棄)'
      )
      assert.equals(
        (
          'review.nvim: worktree %s has uncommitted changes or unsaved buffer edits (%d buffers).'
          .. ' delete and close? (git worktree remove --force '
          .. '— disk and buffer edits are discarded) [y/N]: '
        ):format(wt, 1),
        state.inputs[2].prompt
      )
      assert.same({ 'git', 'worktree', 'remove', '--force', wt }, state.git_calls[3])
      assert.is_true(vim.uv.fs_stat(paths.session_file(state.repo, 'pr-7')) == nil)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  )

  it(
    'delete 残骸の force 確認をキャンセルすると削除を中止し JSON も worktree も untouched',
    function()
      local wt = wt_path 'pr-7'
      vim.fn.mkdir(wt, 'p')
      local file = vim.fs.joinpath(wt, 'a.lua')
      local f = io.open(file, 'w')
      f:write 'line1\nline2\n'
      f:close()
      local buf = vim.fn.bufadd(file)
      vim.fn.bufload(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'USER EDIT' })
      store.save(existing_stub {
        id = 'pr-7',
        mode = 'pr',
        base = 'main',
        head = 'review-nvim/pr-7',
        pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
        worktree = { path = wt, created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
      }
      local n_input = 0
      vim.ui.input = function(opts, cb)
        n_input = n_input + 1
        table.insert(state.inputs, opts)
        -- delete 本体確認は y、force 確認は n (バッファ破棄を拒否)
        cb(n_input == 1 and 'y' or 'n')
      end

      session_handler.delete 'pr-7'

      assert.equals(2, #state.inputs)
      assert.same({ 'git', '-C', wt, 'status', '--porcelain' }, state.git_calls[2])
      assert.equals(2, #state.git_calls) -- remove も update-ref も JSON 削除も走らない
      assert.is_true(vim.uv.fs_stat(paths.session_file(state.repo, 'pr-7')) ~= nil)
      assert.is_true(vim.bo[buf].modified)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  )

  it(
    'closed 残骸の掃除でも worktree 配下のバッファを消してから dir を消す (E211 防止)',
    function()
      local wt = wt_path 'pr-7'
      vim.fn.mkdir(wt, 'p')
      local f = io.open(vim.fs.joinpath(wt, 'a.lua'), 'w')
      f:write 'line1\nline2\n'
      f:close()
      local buf = vim.fn.bufadd(vim.fs.joinpath(wt, 'a.lua'))
      vim.fn.bufload(buf)
      assert.equals(
        1,
        vim.fn.bufexists(buf),
        '前提: 残骸 dir のファイルを指す loaded バッファ'
      )
      store.save(existing_stub {
        id = 'pr-7',
        mode = 'pr',
        base = 'main',
        head = 'review-nvim/pr-7',
        pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
        worktree = { path = wt, created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
        git_ok, -- remove ok
        git_ok, -- update-ref ok
      }
      state.input_answer = 'y'

      session_handler.delete 'pr-7'

      assert.equals(
        0,
        vim.fn.bufexists(buf),
        'delete 掃除でも worktree 配下のバッファを破棄する'
      )
      assert.is_true(vim.uv.fs_stat(paths.session_file(state.repo, 'pr-7')) == nil)
    end
  )

  it(
    'active 同一 id の delete: close (save) -> 自前 worktree の status -> remove -> JSON 削除',
    function()
      started_with_worktree()
      vim.fn.mkdir(wt_path(), 'p') -- add は stub なので dir は自前で作る (掃除対象の実在)
      install_git {
        top_ok,
        git_ok, -- worktree status clean
        git_ok, -- remove ok
      }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.same({ 'git', '-C', wt_path(), 'status', '--porcelain' }, state.git_calls[2])
      assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
      local has_update_ref = false
      for _, cmd in ipairs(state.git_calls) do
        if cmd[2] == 'update-ref' then
          has_update_ref = true
        end
      end
      assert.equals(false, has_update_ref)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
      assert.is_nil(session_handler.active())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
    end
  )

  it(
    'active 同一 id の delete: JSON+ref 削除は remove (手順 3) の投入より先へ進まず、完了を待って実行する',
    function()
      started_with_worktree()
      vim.fn.mkdir(wt_path(), 'p')
      install_git_deferred_remove { top_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      -- remove は投入済みで未完了 (state.deferred)。この時点で JSON が消えて
      -- いると、remove 失敗時に孤児 dir を scan が回収できない — pr-worktree.md
      -- 「セッションの削除」手順 1〜3 完了順の pin。
      assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
      assert.is_true(state.deferred ~= nil)
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)

      state.deferred { code = 0, stdout = '', stderr = '' }

      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
      assert.is_nil(session_handler.active())
      assert.equals(3, #state.git_calls)
    end
  )

  it(
    'active 同一 id の delete で remove 失敗: prune + 自前 dir 削除で回収してから削除完了 (孤児 dir なし)',
    function()
      started_with_worktree()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p') -- remove 失敗後も dir が残る実状態
      install_git_deferred_remove { top_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)
      state.deferred { code = 255, stdout = '', stderr = 'fatal: remove boom\n' }

      -- 回収は WARN なしで完遂 (close の旧経路のような "cleanup failed" はもう出ない)
      assert.equals(0, #state.notifications)
      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.is_true(vim.uv.fs_stat(wt) == nil)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )

  it(
    'active 同一 id の delete で remove も dir 削除も失敗: 中止と WARN、JSON は closed+created_by_us で scan 回収可',
    function()
      started_with_worktree()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      local locked = io.open(vim.fs.joinpath(wt, 'locked.txt'), 'w')
      locked:write 'x\n'
      locked:close()
      -- dir を r-x (書き込み不可) にすると remove_dir の unlink が実 FS 権限で失敗する
      -- (root 実行では成り立たない。make test はローカル非 root 前提 — DESIGN.md)。
      vim.fn.system { 'chmod', '555', wt }
      assert.equals(0, vim.v.shell_error)
      install_git_deferred_remove { top_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)
      state.deferred { code = 255, stdout = '', stderr = 'fatal: remove boom\n' }

      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      local function has_msg(pat)
        for _, n in ipairs(state.notifications) do
          if n.msg:find(pat, 1, true) ~= nil then
            return true
          end
        end
        return false
      end
      assert.is_true(has_msg 'failed to remove the orphaned worktree dir')
      assert.is_false(has_msg 'worktree cleanup failed') -- close の旧経路文言はもう無い
      assert.is_false(has_msg 'failed to delete the worktree dir')
      -- JSON を消さない = closed + created_by_us=true の記録が残る (起動 scan 回収可)。
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.same({ path = wt, created_by_us = true }, load_saved().worktree)

      -- after_each の tmpdir 掃除 (delete 'rf') を通すため権限を戻す
      vim.fn.system { 'chmod', '755', wt }
      assert.equals(0, vim.v.shell_error)
    end
  )

  it(
    'INV-3: created_by_us=false 記録の dir は触れない (active なし delete は JSON ファイルのみ削除)',
    function()
      store.save(existing_stub {
        worktree = { path = wt_path(), created_by_us = false },
      })
      install_git { top_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.equals(1, #state.git_calls)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )

  it(
    'active なし残骸が dirty: --force 確認、キャンセルなら delete 中止 (JSON 保持)',
    function()
      vim.fn.mkdir(wt_path(), 'p')
      store.save(existing_stub {
        worktree = { path = wt_path(), created_by_us = true },
      })
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = ' M a.lua\n', stderr = '' }
        end,
      }
      answer_queue { 'y', 'n' }

      session_handler.delete(SLUG)

      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.equals(2, #state.inputs)
      assert.equals(
        (
          'review.nvim: worktree %s has uncommitted changes. delete and close? '
          .. '(git worktree remove --force — disk edits are discarded) [y/N]: '
        ):format(wt_path()),
        state.inputs[2].prompt
      )
    end
  )

  it(
    '確認は vim.ui.input (cmdline) で行い、応答後に cmdline をクリアする',
    function()
      vim.fn.mkdir(wt_path(), 'p')
      store.save(existing_stub {
        worktree = { path = wt_path(), created_by_us = true },
      })
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = ' M a.lua\n', stderr = '' }
        end,
      }
      local echoes = {}
      local REAL_ECHO = vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks, history, opts)
        table.insert(echoes, { chunks = chunks, history = history, opts = opts })
        return REAL_ECHO(chunks, history, opts)
      end
      local prompts = {}
      vim.ui.input = function(opts, cb)
        prompts[#prompts + 1] = opts.prompt
        cb 'n' -- キャンセル = delete 中止 (このテストの主眼は入力経路と後始末)
      end
      session_handler.delete(SLUG)
      vim.api.nvim_echo = REAL_ECHO
      assert.equals(1, #prompts, 'vim.ui.input (cmdline) 経由で確認していない')
      -- 応答後に cmdline を空 echo で掃除する契約 (残留した打鍵の混入防止)
      local cleared = false
      for _, e in ipairs(echoes) do
        if #e.chunks == 0 and e.history == false then
          cleared = true
        end
      end
      assert.is_true(cleared, '応答後に cmdline クリア (空 echo) が呼ばれない')
    end
  )

  it(
    'remove 失敗 (dir 残る) は prune + 自前 dir remove_dir で回収してから削除を続行',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      store.save(existing_stub {
        worktree = { path = wt, created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
        git_fail 'fatal: remove boom\n', -- remove 失敗
        git_ok, -- prune ok
      }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.is_true(vim.uv.fs_stat(wt) == nil)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )

  it(
    '閉じた残骸で dir まで消せなければ delete を中止して JSON を残す (孤児 dir なし・scan 回収可)',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      local locked = io.open(vim.fs.joinpath(wt, 'locked.txt'), 'w')
      locked:write 'x\n'
      locked:close()
      -- dir を r-x (書き込み不可) にすると remove_dir の unlink が実 FS 権限で
      -- 失敗する (root 実行では成り立たない。make test はローカル非 root 前提)。
      vim.fn.system { 'chmod', '555', wt }
      assert.equals(0, vim.v.shell_error)
      store.save(existing_stub {
        worktree = { path = wt, created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
        git_fail 'fatal: remove boom\n', -- remove 失敗
        git_ok, -- prune ok (dir は rm 不能のまま)
      }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.equals(4, #state.git_calls)
      assert.same({
        msg = 'review.nvim: failed to remove the orphaned worktree dir.'
          .. ' refusing to delete the session rather than leave an orphaned dir: '
          .. wt,
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      -- JSON を消さない = closed + created_by_us の記録が残る (起動 scan が回収できる)
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.same({ path = wt, created_by_us = true }, load_saved().worktree)

      -- after_each の tmpdir 掃除 (delete 'rf') を通すため権限を戻す
      vim.fn.system { 'chmod', '755', wt }
      assert.equals(0, vim.v.shell_error)
    end
  )
end)
