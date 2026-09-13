-- ui/scratchwin: 窓 diff の scratch 側バッファ契約 (docs/design/features/diff-review.md
-- 「head / base 窓の中身」/ DESIGN.md「既知の制約」bufhidden / diffoff 節)。
-- review://<kind>/<session>/<path> の命名・再利用・バッファオプション・
-- filetype detect・deleted/binary 告知内容を pin する。git 実行はを持たない
-- (充填は呼び出し側 = handlers/session。ここで test する no-op 判定の境界)。
local scratchwin = require 'review.ui.scratchwin'

local function cleanup_scratch_bufs()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

describe('scratchwin.buffer 命名・再利用・オプション契約', function()
  before_each(cleanup_scratch_bufs)
  after_each(cleanup_scratch_bufs)

  it('review://<kind>/<session>/<path> の名前で作る (base)', function()
    local buf = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'a.lua' }
    assert.equals('review://base/s1/a.lua', vim.api.nvim_buf_get_name(buf))
  end)

  it('全 kind (base/head/null/deleted/binary) が同じ命名規則', function()
    for _, kind in ipairs { 'base', 'head', 'null', 'deleted', 'binary' } do
      local buf = scratchwin.buffer { kind = kind, session_id = 'ses', path = 'x/y.lua' }
      assert.equals(('review://%s/ses/x/y.lua'):format(kind), vim.api.nvim_buf_get_name(buf))
    end
  end)

  it(
    '同一 path の 2 回目の buffer() は同名バッファを再利用する (窓を増やさない)',
    function()
      local a = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'a.lua' }
      local b = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'a.lua' }
      assert.equals(a, b)
    end
  )

  it('nofile / bufhidden=hide / swapfile off / modifiable false', function()
    local buf = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'a.lua' }
    assert.equals('nofile', vim.bo[buf].buftype)
    assert.equals('hide', vim.bo[buf].bufhidden)
    assert.equals(false, vim.bo[buf].swapfile)
    assert.equals(false, vim.bo[buf].modifiable)
  end)

  it('review_meta は kind=scratch + scratch + session_id + path (drift 判定の源)', function()
    local buf = scratchwin.buffer { kind = 'head', session_id = 's1', path = 'a.lua' }
    assert.same(
      { kind = 'scratch', scratch = 'head', session_id = 's1', path = 'a.lua' },
      vim.b[buf].review_meta
    )
  end)
end)

describe('scratchwin.set_content / detect_filetype', function()
  before_each(cleanup_scratch_bufs)
  after_each(cleanup_scratch_bufs)

  it('set_content は read-only のまま中身だけを反映する', function()
    local buf = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'a.lua' }
    scratchwin.set_content(buf, { 'line1', 'line2' })
    assert.same({ 'line1', 'line2' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals(false, vim.bo[buf].modifiable)
  end)

  it(
    'set_content の再適用は内容を全面置換する (差分再取得で残行を残さない)',
    function()
      local buf = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'a.lua' }
      scratchwin.set_content(buf, { 'old1', 'old2' })
      scratchwin.set_content(buf, { 'new1' })
      assert.same({ 'new1' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end
  )

  it(
    'null kind は中身なし scratch (追加ファイルの base 側。0 行表示 = diff ペア参加)',
    function()
      local buf = scratchwin.buffer { kind = 'null', session_id = 's1', path = 'b.lua' }
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local empty = #lines == 0 or (#lines == 1 and lines[1] == '')
      assert.is_true(empty, 'null scratch に内容が残っている: ' .. vim.inspect(lines))
    end
  )

  it('detect_filetype は拡張子から buffer filetype を当てる (lua → lua)', function()
    local buf = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'a.lua' }
    scratchwin.detect_filetype(buf, 'a.lua')
    assert.equals('lua', vim.bo[buf].filetype)
  end)

  it('detect_filetype は判定不能拡張子で filetype を空のままにする', function()
    local buf = scratchwin.buffer { kind = 'base', session_id = 's1', path = 'nope.unknownext' }
    scratchwin.detect_filetype(buf, 'nope.unknownext')
    assert.equals('', vim.bo[buf].filetype)
  end)

  it('deleted / binary 告知窓の確定文言 (1 行)', function()
    assert.same(
      { '■ deleted (head に存在しません — base 側は左窓)' },
      scratchwin.NOTIFY.deleted
    )
    assert.same({ 'Binary files differ' }, scratchwin.NOTIFY.binary)
  end)
end)
