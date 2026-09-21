-- handlers/worktree_buffers: worktree dir 配下のバッファ走査ヘルパーの単位検証。
-- 呼び出し側 (health/session) の統合テストとは別に、境界 (review:// 除外 / dir 外 /
-- modified のみ計数) を直接 pin する。no-op 化変異は両 describe の正 assert でkill。
local bufs = require 'review.handlers.worktree_buffers'

local state = {}

-- 実ファイルを作って loaded バッファにする (E211 経路と同じ bufadd + bufload)。
-- dir = state.dir を基準にする (modified = 未保存編集を載せる)。
local function loaded_buf(relpath, modified)
  local file = vim.fs.joinpath(state.dir, relpath)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ':h'), 'p')
  local f = io.open(file, 'w')
  f:write 'line1\nline2\n'
  f:close()
  local b = vim.fn.bufadd(file)
  vim.fn.bufload(b)
  if modified then
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'EDIT' })
    assert.equals(true, vim.bo[b].modified)
  end
  table.insert(state.created, b)
  return b
end

-- state.dir の外に同名形状の実ファイル loaded バッファ (dir 外温存の对照)。
local function loaded_outside_buf()
  local file = vim.fn.tempname()
  local f = io.open(file, 'w')
  f:write 'x\n'
  f:close()
  local b = vim.fn.bufadd(file)
  vim.fn.bufload(b)
  table.insert(state.created, b)
  table.insert(state.out_files, file)
  return b
end

local function use_env()
  before_each(function()
    state = { dir = vim.fn.tempname(), created = {}, out_files = {} }
    vim.fn.mkdir(state.dir, 'p')
  end)
  after_each(function()
    for _, b in ipairs(state.created) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    for _, f in ipairs(state.out_files) do
      pcall(os.remove, f)
    end
    vim.fn.delete(state.dir, 'rf')
  end)
end

describe('worktree_buffers.destroy', function()
  use_env()

  it(
    'dir 配下の loaded 実ファイルバッファだけ消す (review:// と dir 外は温存)',
    function()
      local inside = loaded_buf('a.lua', false)
      local nested = loaded_buf('sub/b.lua', false)
      local review_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(review_buf, 'review://base/sx/a.lua')
      table.insert(state.created, review_buf)
      local outside = loaded_outside_buf()

      bufs.destroy(state.dir)

      -- 陽性 (消えるべき分): dir 配下の 2 つ (ネスト含む)
      assert.equals(0, vim.fn.bufexists(inside))
      assert.equals(0, vim.fn.bufexists(nested))
      -- 陰性 (触らない): review:// scratch と dir 外実ファイル
      assert.equals(1, vim.fn.bufexists(review_buf))
      assert.equals(1, vim.fn.bufexists(outside))
    end
  )

  it(
    'modified バッファでも force で消す (delete の force wipe と同じ破棄契約)',
    function()
      local m = loaded_buf('m.lua', true)

      bufs.destroy(state.dir)

      assert.equals(0, vim.fn.bufexists(m))
    end
  )
end)

describe('worktree_buffers.count_modified', function()
  use_env()

  it(
    'dir 配下の modified だけを数える (dir 内 clean と dir 外 modified を除外)',
    function()
      assert.equals(0, bufs.count_modified(state.dir))

      loaded_buf('clean.lua', false)
      loaded_buf('mod.lua', true)
      loaded_buf('sub/mod2.lua', true)
      local outside = loaded_outside_buf()
      vim.bo[outside].modifiable = true
      vim.api.nvim_buf_set_lines(outside, 0, -1, false, { 'EDIT' })
      assert.equals(true, vim.bo[outside].modified)

      assert.equals(2, bufs.count_modified(state.dir))
    end
  )

  it(
    'modified を増らすと増える (カウントは現在値、cache していない)',
    function()
      loaded_buf('mod.lua', true)
      assert.equals(1, bufs.count_modified(state.dir))

      loaded_buf('mod2.lua', true)
      assert.equals(2, bufs.count_modified(state.dir))
    end
  )
end)
