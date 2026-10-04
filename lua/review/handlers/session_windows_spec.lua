-- handlers/session: 専有 tab の head / base 窓の中身 (窓張り分け表: 追加 / 削除 /
-- rename / binary)、集約先 head 窓の無い outdated の panel winbar ⚠N、コメント箱幅の
-- リサイズ追従、commit_comment_change (INV-4 save + extmark 再適用)。
-- 共有の開始部品は tests/helpers/session_fixtures.lua (session_spec と同じ土俵)。
local session_handler = require 'review.handlers.session'
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
local existing_stub = sf.existing_stub
local calls_of = sf.calls_of
local inject_comment = sf.inject_comment
local inject_outdated = sf.inject_outdated
local use_env = sf.use_env
local RP_HEAD_MATCH = sf.RP_HEAD_MATCH
local RP_HEAD_MISMATCH = sf.RP_HEAD_MISMATCH
local showref_ok = sf.showref_ok
local status_clean = sf.status_clean
local start_done = sf.start_done
local review_tab = session_env.review_tab
local head_buf_name = session_env.head_buf_name
local base_buf_name = session_env.base_buf_name

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

local function inject_comment_at(line, body)
  inject_comment(body, 'a.lua', line)
end

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
      assert.same(
        { '■ deleted (absent from head — base side is in the left window)' },
        vim.api.nvim_buf_get_lines(head_buf, 0, -1, false)
      )
      -- 削除は告知ペア (head 告知 1 行 / base 旧内容) なので両窓で窓 diff を抜ける
      -- (相手のいない diff ペアを作らない — issue #38)
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      assert.equals(false, vim.wo[ui_windows.win 'base'].diff)
      -- git show 充填は base 窓のみ (head 実ファイル編集事故を作らない)
      assert.same({ { 'git', 'show', 'main:c.lua' } }, calls_of 'show')
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
      assert.same({}, calls_of 'show')
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
      assert.same({ { 'git', 'show', 'main:a.lua' } }, calls_of 'show')
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
    assert.equals(' \u{EA6B} 2', vt)
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
      assert.equals('M a.lua +1 -0', row_of 'a.lua', '前提: コメント 0 件の行')
      inject_comment 'first thread'
      assert.equals(
        'M \u{EA6B} a.lua +1 -0',
        row_of 'a.lua',
        'コメントアイコンが反映されない'
      )
      -- 削除 (最後の 1 件) でアイコンも消える (同じ render 経路)
      table.remove(session_handler.active().comments, 1)
      session_handler.commit_comment_change()
      assert.equals('M a.lua +1 -0', row_of 'a.lua', 'panel 行からアイコンが消えない')
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
      -- 集約の箱の中身 (罫線・区切り・右 pad を除く)。実窓では箱幅 = 窓幅で見出しが
      -- 折り返されるため、見出しは連結し、以降のコメント行 (id 行 + 本文) と分けて返す。
      local function outdated_box()
        local heading, rows = {}, {}
        local marks = vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })
        for _, m in ipairs(marks) do
          for _, line in ipairs(m[4].virt_lines or {}) do
            if #line >= 4 then
              local chunk = line[2]
              local text = type(chunk[1]) == 'table' and chunk[1][1] or chunk[1]
              if #rows == 0 and text:sub(1, 3) ~= '  [' then
                heading[#heading + 1] = text
              else
                rows[#rows + 1] = text
              end
            end
          end
        end
        return { heading = table.concat(heading), rows = rows }
      end
      local function mark_count()
        return #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {})
      end
      assert.equals(1, mark_count(), '前提: 集約 mark が 1 件 (placeholder 開通直後)')
      assert.same({
        heading = ' 2 outdated (excluded from prompt)',
        rows = { '  [c1]', 'ghost one', '  [c2]', 'ghost two' },
      }, outdated_box())

      -- placeholder 窓での削除 (commit_comment_change 経路): clear_tracked 後も
      -- no-changes への再適用で集約が復活する (real / degraded と同一条件)。
      table.remove(session_handler.active().comments, 1)
      session_handler.commit_comment_change()

      assert.equals(1, mark_count(), '削除後に集約 mark が消えたまま復活しない')
      assert.same({
        heading = ' 1 outdated (excluded from prompt)',
        rows = { '  [c2]', 'ghost two' },
      }, outdated_box())
    end
  )
end)

-- ---------------------------------------------------------------------------
-- pr worktree (作成判断 / 記録再利用 / 直列化)
-- ---------------------------------------------------------------------------
