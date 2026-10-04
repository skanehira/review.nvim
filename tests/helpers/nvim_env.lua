-- spec 共有: nvim プロセス共有状態 (tabpage / review://* バッファ / vim 組み込み関数)
-- の隔離プリミティブ。plenary busted は describe 外のフックを持たないので、
-- フックの登録は各 spec の use_env() 側で行い、ここは手続きだけを提供する。
local M = {}

-- vim 組み込み関数はプロセス単一なので real 参照は require 時に 1 回捕捉する
-- (before_each ごとに見ると spy が入れ子になり after_each の復旧先が壊れる)。
-- spec 先頭で require される = どの spy よりも前に評価される。
M.REAL_NOTIFY = vim.notify
M.REAL_INPUT = vim.ui.input
M.REAL_SELECT = vim.ui.select

M.CY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

--- `review://` 名の valid バッファを全て強制削除する (前テスト残りの同名再利用の混線防止)。
function M.wipe_review_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

--- 全 tabpage を順に閉じる (最後の 1 枚は閉じられずに残る)。
function M.close_all_tabs()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      pcall(vim.cmd, 'tabclose!')
    end
  end
end

--- tab が valid なら current にして閉じる。
function M.close_tab(tab)
  if tab ~= nil and vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    pcall(vim.cmd, 'tabclose!')
  end
end

--- それまでに予約された vim.schedule を全て流す。番兵を最後に積み、番兵が走った
--- 時点でそれ以前の予約は実行済み (FIFO)。「発火しないこと」を固定時間の sleep で
--- 待つと、遅い環境では未実行のまま通ってしまうため、こちらで待つ。
function M.drain_scheduled()
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  assert(
    vim.wait(1000, function()
      return drained
    end, 5),
    'vim.schedule の予約が流れない'
  )
end

--- 隔離 tabpage を作って current にし、state.tab に記録して返す。
function M.isolate_tab(state)
  vim.cmd 'tabnew'
  state.tab = vim.api.nvim_get_current_tabpage()
  return state.tab
end

return M
