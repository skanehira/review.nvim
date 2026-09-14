-- ui/syntaxhl: filepanel のファイル名に Neovim 内蔵 syntax の色を写す
-- (docs/design/features/diff-review.md「file panel」)。basename を一時 scratch buf に
-- 入れて当該 filetype の syntax をロードし、1 byte ずつ synIDattr(synID(...)) で取れた
-- highlight group を連続区間に畳んで返す。呼び出し側 (filepanel) はその区間へ
-- 既存の ReviewPanelFile span を置換する extmark を張る。
--
-- 副作用抑制 (DESIGN「UI」の FileType autocmd 不使用方針との整合):
-- filetype 解決には vim.filetype.match (純関数) を使い、scratch buffer には
-- &syntax を直接設定して syntax item をロードする。setfiletype / FileType autocmd
-- は一切踏まないため、ユーザの matchparen / LSP / treesitter auto-attach 等の
-- side effect 経路がない。窓も noautocmd の off-screen 1x1 で BufWinEnter 等も
-- 発火しない。窓は即閉じ、scratch buffer は再利用 (wipe しない)。
local M = {}

local scratch_buf = nil
local enabled = false

-- ft + name -> spans (or false = 解決不能)。同一 name が render ごとに何度も引かれる
-- ので cache する (synID 呼び出しを毎回走らせない = 大きなツリーの描画コスト対策)。
local cache = {}

-- 色として意味を持たない group 名 (synID が空か既定に戻る)。この区間は span に
-- 入れない = 呼び出し側の ReviewPanelFile (既定色) がそのまま残る。
local function ignorable(group)
  return group == nil
    or group == ''
    or group == 'Normal'
    or group == 'NormalGO'
    or group == 'Nothing'
end

local function scratch()
  if scratch_buf ~= nil and vim.api.nvim_buf_is_valid(scratch_buf) then
    return scratch_buf
  end
  scratch_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch_buf].buftype = 'nofile'
  vim.bo[scratch_buf].bufhidden = 'hide'
  vim.bo[scratch_buf].swapfile = false
  vim.bo[scratch_buf].undofile = false
  return scratch_buf
end

-- name 1 行を scratch に載せ filetype を当て、col 単位の group を返す。
-- 窓は off-screen 最小 float — 画面上どこにも見えない (実測: 可視窓を汚さない)。
local function columns_for(name, ft)
  local buf = scratch()
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = 1,
    height = 1,
    row = -4,
    col = -4,
    zindex = 1,
    style = 'minimal',
    border = 'none',
    focusable = false,
    noautocmd = true,
  })
  local ok, groups = pcall(function()
    return vim.api.nvim_win_call(win, function()
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { name })
      -- &syntax 直設定 (setfiletype/FileType autocmd は使わない)。syntax 名が変わる
      -- 時だけ再ロードし、同一 syntax の別 name は set_lines だけで足りる。
      -- FileType を踏まないためユーザの matchparen/LSP/treesitter attach 等の
      -- side effect 経路がない (0.13 では FileType 経由だと treesitter highlighter が
      -- b:ts_highlight を立て syntax.vim の syntaxset がロードを省略する、という
      -- 競合も観測されている — 直接設定はそれを迂回する)。
      if vim.bo[buf].syntax ~= ft then
        vim.bo[buf].syntax = ft
      end
      local out = {}
      for col = 1, #name do
        out[col] = vim.fn.synIDattr(vim.fn.synID(1, col, 1), 'name')
      end
      vim.bo[buf].modifiable = false
      return out
    end)
  end)
  pcall(vim.api.nvim_win_close, win, true)
  if not ok or groups == nil then
    return nil
  end
  return groups
end

-- group 配列 (1-based col -> name) を {from,to,group} (0-based, byte [from,to)) 区間へ。
local function to_spans(groups, len)
  local spans = {}
  local i = 1
  while i <= len do
    local g = groups[i]
    if not ignorable(g) then
      local j = i
      while j < len and groups[j + 1] == g do
        j = j + 1
      end
      spans[#spans + 1] = { from = i - 1, to = j, group = g }
      i = j + 1
    else
      i = i + 1
    end
  end
  return spans
end

--- basename の syntax color span を返す (無ければ nil)。
--- spans = { {from=0-based-byte, to=byte(exclusive), group=hlname}, ... }。
function M.spans(name)
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  local ft = vim.filetype.match { filename = name }
  if ft == nil or ft == '' then
    return nil
  end
  local key = ft .. '\1' .. name
  local hit = cache[key]
  if hit ~= nil then
    if hit == false then
      return nil
    end
    return hit
  end
  if not enabled then
    vim.cmd 'syntax enable'
    enabled = true
  end
  local groups = columns_for(name, ft)
  if groups == nil then
    cache[key] = false
    return nil
  end
  local spans = to_spans(groups, #name)
  if #spans == 0 then
    cache[key] = false
    return nil
  end
  cache[key] = spans
  return spans
end

--- 窓・cache・syntax 有効状態をリセット (test/終了用)。
function M.reset()
  if scratch_buf ~= nil and vim.api.nvim_buf_is_valid(scratch_buf) then
    pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
  end
  scratch_buf = nil
  cache = {}
  enabled = false
end

return M
