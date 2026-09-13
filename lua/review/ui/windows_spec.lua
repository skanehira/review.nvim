-- ui/windows: 専有 tabpage 3 窓 (panel│base│head) の開通・role 導出・drift 復旧・
-- 消滅経路 (docs/design/features/diff-review.md「レイアウト (専有 tabpage 3 窓)」
-- 「窓 role は id ではなく内容 + 窓変数から導く」「review tab の消滅経路」/
-- DESIGN.md「窓の所有」)。窓の配置と窓変数だけを担当し、buf の中身
-- (git show 充填 / :edit / キーマップ張込) は組み立てない (handlers + scratchwin +
-- keygate の責務)。
-- pin する契約:
--   * vsplit 継承 drift 回避 = 窓を先に作ってから set_buf (vsplit の新窓は現 buf を継承する)
--   * 位置は splitright に依らず panel 左 / base 中 / head 右 (wincmd H/L で寄せる)
--   * 開通時 tcd、head/base 窓 opts、開通 focus = head 窓
--   * role は窓変数 gate + 表示 buf 指紋から導く (別窓で同じ buf を見せても head 不成立)
local windows = require 'review.ui.windows'

local OTHER_DIR = vim.uv.fs_realpath '/tmp' or '/tmp'

local scratch_bufs = {}

local function scratch_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.api.nvim_buf_set_name(buf, name)
  scratch_bufs[#scratch_bufs + 1] = buf
  return buf
end

local state = {}

local function use_env()
  before_each(function()
    scratch_bufs = {}
    state.old_notify = vim.notify
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if windows.state() ~= nil then
      windows.close()
    end
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.api.nvim_tabpage_is_valid(tab) and tab ~= state.tab then
        vim.api.nvim_set_current_tabpage(tab)
        pcall(vim.cmd, 'tabclose!')
      end
    end
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      pcall(vim.cmd, 'tabclose!')
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    for _, buf in ipairs(scratch_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.notify = state.old_notify
    windows.reset()
    require('review.config').reset()
  end)
end

describe('windows.open: 専有 tab 3 窓の開通', function()
  use_env()

  it(
    'tabnew でレビュー専有 tab を作り 3 窓 (ユーザーの元 tab は 1 窓のまま)',
    function()
      local before_tabs = #vim.api.nvim_list_tabpages()
      windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
      local st = windows.state()
      assert.is_true(st ~= nil)
      assert.is_true(vim.api.nvim_tabpage_is_valid(st.tab))
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(st.tab))
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(state.tab))
      assert.equals(
        before_tabs + 1,
        #vim.api.nvim_list_tabpages(),
        'レビュー tab が 1 個増えた状態が期待値'
      )
    end
  )

  it('位置は panel 左 / base 中 / head 右', function()
    windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
    local pos = function(role)
      return vim.fn.win_screenpos(windows.win(role))[2]
    end
    assert.is_true(pos 'panel' < pos 'base', 'panel が base より右')
    assert.is_true(pos 'base' < pos 'head', 'base が head より右')
  end)

  it('splitright がどちらでも位置は同じ (wincmd L で寄せる契約)', function()
    vim.o.splitright = false
    windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
    local pos = function(role)
      return vim.fn.win_screenpos(windows.win(role))[2]
    end
    assert.is_true(pos 'panel' < pos 'base')
    assert.is_true(pos 'base' < pos 'head')
    vim.o.splitright = true
  end)

  it('開通 focus は head 窓 (直後の c/e が効く位置から開始)', function()
    windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
    assert.equals(windows.win 'head', vim.api.nvim_get_current_win())
  end)

  it('panel 窓幅は config.panel_width + winfixwidth', function()
    local config = require 'review.config'
    config.setup { panel_width = 27 }
    windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
    local sb = windows.win 'panel'
    assert.equals(27, vim.api.nvim_win_get_width(sb))
    assert.equals(true, vim.wo[sb].winfixwidth)
  end)

  it(
    'head/base 窓 opts (diff/scrollbind/cursorbind/foldmethod=diff/foldcolumn/wrap=off)',
    function()
      windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
      -- opts は bind (buf 張付) の時点で適用する (空窓での fold 計算壊れ回避 —
      -- windows.open のコメント)。張付後の窓がレビュー窓契約を満たすことを見る。
      windows.bind(scratch_buf 'review://base/sx/opts.lua', scratch_buf 'review://head/sx/opts.lua')
      for _, role in ipairs { 'base', 'head' } do
        local w = windows.win(role)
        assert.equals(true, vim.wo[w].diff)
        assert.equals(true, vim.wo[w].scrollbind)
        assert.equals(true, vim.wo[w].cursorbind)
        assert.equals('diff', vim.wo[w].foldmethod)
        assert.equals(0, vim.wo[w].foldlevel)
        assert.equals(1, tonumber(vim.wo[w].foldcolumn))
        assert.equals(false, vim.wo[w].wrap)
      end
    end
  )

  it(
    'diffopt (world option) をレビュー側から変更しない (DESIGN 既知の制約)',
    function()
      local before = vim.o.diffopt
      windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
      assert.equals(before, vim.o.diffopt)
    end
  )

  it(
    '開通時に tab-local cwd を dir へ tcd する (ユーザー tab に漏れない)',
    function()
      local gwd = vim.fn.getcwd()
      windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
      -- getcwd(-1, 0) = 現 tab (tcd 適用下) の cwd
      assert.equals(OTHER_DIR, vim.fn.getcwd(-1, 0))
      vim.api.nvim_set_current_tabpage(state.tab)
      assert.equals(gwd, vim.fn.getcwd(-1, 0), 'ユーザー tab に tcd が漏れている')
    end
  )

  it(
    '存在しない dir でも tcd で開通を中断しない (3 窓は開く。tab 残留のまま UI 不能を作らない)',
    function()
      windows.open {
        dir = vim.fs.joinpath(vim.fn.tempname(), 'not-created'),
        on_tab_closed = function() end,
      }
      local st = windows.state()
      assert.is_true(st ~= nil)
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(st.tab))
    end
  )
end)

describe('windows.bind / set_panel_buf: role 導出', function()
  use_env()

  local base_buf, head_buf

  before_each(function()
    windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
    base_buf = scratch_buf 'review://base/s/a.lua'
    head_buf = scratch_buf 'review://head/s/a.lua'
  end)

  it(
    'bind 前はレビュー内容がどの窓にも乗っていないので role は nil',
    function()
      assert.is_nil(windows.role_of(windows.win 'base'))
      assert.is_nil(windows.role_of(windows.win 'head'))
      assert.is_nil(windows.role_of(windows.win 'panel'))
    end
  )

  it('bind 後: base/head が窓変数 gate + 表示 buf 指紋から導ける', function()
    windows.bind(base_buf, head_buf)
    assert.equals('base', windows.role_of(windows.win 'base'))
    assert.equals('head', windows.role_of(windows.win 'head'))
  end)

  it(
    '実ファイル head も gate で head 導出 (review:// 命名に依存しない)',
    function()
      local real = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(real, '/tmp/review-spec-real.lua')
      windows.bind(base_buf, real, { head_kind = 'real' })
      assert.equals('head', windows.role_of(windows.win 'head'))
    end
  )

  it(
    '別窓で同じ head buf を見せても head にならない (gate 不成立窓 = built-in)',
    function()
      local real = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(real, '/tmp/review-spec-real2.lua')
      windows.bind(base_buf, real, { head_kind = 'real' })
      vim.api.nvim_set_current_tabpage(state.tab)
      local uw = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(uw, real)
      assert.is_nil(windows.role_of(uw))
    end
  )

  it(
    'binary 共有窓: 同一 buf を base/head 両窓に張れる + diffoff=both で両窓が窓 diff から抜ける',
    function()
      local shared = scratch_buf 'review://binary/s/a.lua'
      windows.bind(shared, shared, { diffoff = 'both' })
      assert.equals(2, #vim.fn.win_findbuf(shared))
      assert.equals('base', windows.role_of(windows.win 'base'))
      assert.equals('head', windows.role_of(windows.win 'head'))
      -- diffoff の検証可能形 = 窓 diff から抜けている (foldclosed だと単独窓で不定)
      assert.equals(false, vim.wo[windows.win 'base'].diff)
      assert.equals(false, vim.wo[windows.win 'head'].diff)
    end
  )

  it(
    'deleted: diffoff=head は head 窓だけ窓 diff から抜ける (base 窓は窓 diff を継続)',
    function()
      windows.bind(base_buf, head_buf, { diffoff = 'head' })
      assert.equals(false, vim.wo[windows.win 'head'].diff)
      assert.equals(true, vim.wo[windows.win 'base'].diff)
      -- gate 役割は抜いても張られたまま (base/head 張り分けの契約は不変)
      assert.equals('base', windows.role_of(windows.win 'base'))
      assert.equals('head', windows.role_of(windows.win 'head'))
    end
  )

  it(
    'diffoff 退避は foldclosed()==-1 で観測できる (窓 diff folded の陽性対照付き)',
    function()
      -- foldmethod=diff は同一領域を閉じる (変更行は常に見える)。40 行中 20 行目
      -- だけ違う pair で 2/30 行目の fold を陽性対照に、diffoff 後は -1 を assert
      -- (DESIGN「既知の制約」窓 diff の退避検証形。`:diffoff` は foldmethod を元へ
      -- 戻さず、manual にしても diff 由来の保存 fold は残るため zE 解消が要る —
      -- apply_diffoff の foldmethod=manual + zE を同時に検証)。
      local b1 = scratch_buf 'review://base/sx/foldy.lua'
      local h1 = scratch_buf 'review://head/sx/foldy.lua'
      local a, h = {}, {}
      for i = 1, 40 do
        a[i] = 'l' .. i
        h[i] = 'l' .. i
      end
      h[20] = 'CHANGED-20'
      vim.bo[b1].modifiable = true
      vim.api.nvim_buf_set_lines(b1, 0, -1, false, a)
      vim.bo[h1].modifiable = true
      vim.api.nvim_buf_set_lines(h1, 0, -1, false, h)
      windows.bind(b1, h1)
      local fc = function(w, row)
        return vim.api.nvim_win_call(w, function()
          return vim.fn.foldclosed(row)
        end)
      end
      assert.is_true(
        fc(windows.win 'head', 2) >= 1,
        '陽性対照: line2 が窓 diff で fold されていない'
      )
      assert.is_true(
        fc(windows.win 'head', 30) >= 1,
        '陽性対照: line30 が窓 diff で fold されていない'
      )
      windows.bind(b1, h1, { diffoff = 'both' })
      assert.equals(
        -1,
        fc(windows.win 'head', 2),
        'diffoff 後も fold が残っている (zE 漏れ)'
      )
      assert.equals(
        -1,
        fc(windows.win 'head', 30),
        'diffoff 後も fold が残っている (zE 漏れ)'
      )
      assert.equals(false, vim.wo[windows.win 'head'].diff)
      assert.equals(false, vim.wo[windows.win 'base'].diff)
    end
  )

  it(
    'set_panel_buf で panel role が内容から導ける (review://sidebar バッファ)',
    function()
      local sb = scratch_buf 'review://sidebar/s'
      windows.set_panel_buf(sb)
      assert.equals('panel', windows.role_of(windows.win 'panel'))
      -- base 窓に sidebar buf を乗せ替えると、その窓が panel として導出される
      -- (窓 id でなく内容から導く契約。drift 復旧の根拠)
      local bw = windows.win 'base'
      vim.api.nvim_win_set_buf(bw, sb)
      assert.equals('panel', windows.role_of(bw))
    end
  )

  it(
    'bind は窓が消えていればペアを再建する (drift 復旧。open_file 再張付の前提)',
    function()
      windows.bind(base_buf, head_buf)
      local old_head = windows.win 'head'
      vim.api.nvim_win_close(old_head, true)
      windows.bind(base_buf, head_buf)
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(windows.state().tab))
      assert.equals('head', windows.role_of(windows.win 'head'))
      assert.equals('base', windows.role_of(windows.win 'base'))
      -- 再建窓にも窓 diff opts が効いている
      assert.equals('diff', vim.wo[windows.win 'head'].foldmethod)
    end
  )

  it('bind は内容が差し替わった窓へ張り直して復旧する', function()
    windows.bind(base_buf, head_buf)
    local head_w = windows.win 'head'
    vim.api.nvim_win_set_buf(head_w, scratch_buf '/tmp/review-drift.lua')
    assert.is_nil(windows.role_of(head_w))
    windows.bind(base_buf, head_buf)
    assert.equals('head', windows.role_of(windows.win 'head'))
  end)
end)

describe('windows panel toggle', function()
  use_env()

  local sb_buf

  before_each(function()
    windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
    sb_buf = scratch_buf 'review://sidebar/s'
    windows.set_panel_buf(sb_buf)
  end)

  it('hide_panel で panel 窓を閉じても tab とレビュー窓は残る (2 窓)', function()
    windows.hide_panel()
    local st = windows.state()
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(st.tab))
    assert.is_nil(windows.win 'panel')
    assert.is_true(vim.api.nvim_win_is_valid(windows.win 'head'))
  end)

  it('show_panel で panel を左に再建し role が効く', function()
    windows.hide_panel()
    windows.show_panel(sb_buf)
    local st = windows.state()
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(st.tab))
    assert.equals('panel', windows.role_of(windows.win 'panel'))
    assert.is_true(
      vim.fn.win_screenpos(windows.win 'panel')[2] < vim.fn.win_screenpos(windows.win 'base')[2]
    )
  end)
end)

describe('windows: q (close) と :tabclose の両経路', function()
  use_env()

  it(
    'close() はレビュー tab を閉じ state を nil にし on_tab_closed を発火しない',
    function()
      local called = 0
      windows.open {
        dir = OTHER_DIR,
        on_tab_closed = function()
          called = called + 1
        end,
      }
      local tab = windows.state().tab
      windows.close()
      assert.is_nil(windows.state())
      assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
      vim.wait(50)
      assert.equals(0, called, 'programmatic close は tab 消滅経路と区別される')
    end
  )

  it(
    'ユーザーが :tabclose で閉じると on_tab_closed が 1 回だけ呼ばれ state が落ちる',
    function()
      local called = 0
      windows.open {
        dir = OTHER_DIR,
        on_tab_closed = function()
          called = called + 1
        end,
      }
      local tab = windows.state().tab
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd 'tabclose!'
      vim.wait(200, function()
        return called > 0
      end)
      assert.equals(1, called)
      assert.is_nil(windows.state())
    end
  )

  it('state が無いときの close は no-op で安全', function()
    windows.close()
    assert.is_nil(windows.state())
  end)
end)

describe('windows.sweep: 専有 tab 内の空窓回収', function()
  use_env()

  it('float 破片/error で残った [No Name] 空窓を閉じて 3 窓に戻す', function()
    windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
    vim.api.nvim_set_current_win(windows.win 'head')
    vim.cmd 'vsplit'
    vim.cmd 'enew'
    assert.equals(4, #vim.api.nvim_tabpage_list_wins(windows.state().tab))
    windows.sweep()
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(windows.state().tab))
  end)

  it(
    '内容のある窓 (ユーザーが review tab で編集したもの) は回収しない',
    function()
      windows.open { dir = OTHER_DIR, on_tab_closed = function() end }
      vim.api.nvim_set_current_win(windows.win 'head')
      vim.cmd 'vsplit'
      vim.cmd 'enew'
      vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { 'note' })
      windows.sweep()
      assert.equals(4, #vim.api.nvim_tabpage_list_wins(windows.state().tab))
    end
  )
end)
