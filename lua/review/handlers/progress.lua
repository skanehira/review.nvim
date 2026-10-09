-- 開始フローの段階別過渡メッセージ (pr-worktree.md「段階別の過渡メッセージ」)。
-- 並行する段階は開始順に 1 行へ併記し、全段階が終わったらメッセージエリアを
-- 空 echo でクリアする。カスタム notify プロバイダ向けの `{hide=id}` は使わない:
-- 既定の vim.notify は echo のみで id 指定の非表示を持たないため。
local M = {}

local function echo_width()
  return vim.v.echospace
end

local width = echo_width

-- メッセージ欄の幅を超える 1 行は折り返されて Press ENTER の確認待ちになり、
-- 開始フローの後続コールバックが止まる (長い base ブランチ名・段階の併記で起きる)。
-- 末尾を切り詰めて 1 行に収める。
local function fit(text)
  local max = width()
  if vim.fn.strdisplaywidth(text) <= max then
    return text
  end
  local keep = max - 3
  local head = ''
  for i = 0, vim.fn.strchars(text) - 1 do
    local next_head = head .. vim.fn.strcharpart(text, i, 1)
    if vim.fn.strdisplaywidth(next_head) > keep then
      break
    end
    head = next_head
  end
  return (head:gsub('%s+$', '')) .. '...'
end

local function default_sink(text)
  if text == nil then
    vim.api.nvim_echo({}, false, {})
    return
  end
  vim.notify(fit(text), vim.log.levels.INFO)
end

local sink = default_sink
local running = {}
local next_handle = 0

local function render()
  if #running == 0 then
    sink(nil)
    return
  end
  local labels = {}
  for i, stage in ipairs(running) do
    labels[i] = stage.label
  end
  sink('review.nvim: ' .. table.concat(labels, ', ') .. '...')
end

--- 段階を開始して表示に加える。戻り値の handle を stop に渡す。
function M.start(label)
  next_handle = next_handle + 1
  table.insert(running, { handle = next_handle, label = label })
  render()
  return next_handle
end

--- 段階を終えて表示から外す。終了済みの handle は無視する。
function M.stop(handle)
  for i, stage in ipairs(running) do
    if stage.handle == handle then
      table.remove(running, i)
      render()
      return
    end
  end
end

function M._set_sink(fn)
  sink = fn or default_sink
end

function M._set_width(fn)
  width = fn or echo_width
end

function M._reset()
  running = {}
end

return M
