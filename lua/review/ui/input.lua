-- マルチラインコメント入力 float (diff-review.md「操作」c / e)。
-- 操作契約:
--   insert: <CR> は改行 / <C-y> は確定のエイリアス
--   Normal: <CR> で確定 / q で閉じる (本文なし=キャンセルで即閉、本文あり=
--     閉じず WARN、discard window 内にもう一度 q で入力を破棄して閉じる)
--   <Esc> は Normal へ戻るだけで窓を閉じない (入力を失わない)
--   :q 等の窓離脱は従来どおりキャンセル
-- 世界との契約: on_confirm(body) は確定操作でのみ呼ばれる。空 body の確定・
-- 空のまま q・double q 破棄・窓離脱では一切呼ばれない。
-- 破棄の誤爆防止: 本文ありの q は armed になるだけで閉じず、armed は本文編集で
-- 解除、discard window (2s) 経過でリセット。
local M = {}

local DISCARD_WINDOW_S = 2.0

local function default_now()
  return ((vim.uv or vim.loop).hrtime()) / 1e9
end

local now_fn = default_now

--- テストフック: 時刻針の注入 (nil で本物へ戻す)。
function M._set_now(fn)
  now_fn = fn or default_now
end

--- opts = { value?, on_confirm(body) }。
--- 空 body (空白のみ) の確定はキャンセル扱い (決定: 空コメントを作らない)。
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false

  local lines = opts.value ~= nil and vim.split(opts.value, '\n', { plain = true }) or {}
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.max(20, math.min(70, vim.o.columns - 4))
  local height = math.max(4, math.min(12, #lines + 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    border = 'rounded',
    -- 確定/閉じるの操作は Discoverability の中心 (help だけでなく常時見える
    -- 場所に置く — README / doc/review.txt / <F1> help も同一契約)。
    title = ' Comment  <CR> 確定  q 閉じる ',
  })

  -- 解決済みフラグ。窓クローズ経路 (確定 / q / :q 等) と二重発火しないための境界。
  local settled = false
  -- 本文あり q の待機状態 { at, body }。破棄は「同じ本文のまま discard window 内に
  -- もう一度 q」のみとする — 本文が変わっていれば arming し直し。TextChanged 系は
  -- updatetime 遅延発火で確実ではないため、判定は q 押下時点の本文比較で行う
  -- (テストでも決定論的に検証できる)。
  local armed = nil

  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  local function body_text()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  end

  local function confirm()
    if settled then
      return
    end
    local body = body_text()
    if body:match '^%s*$' then
      settled = true
      close_window()
      return -- 空 body はキャンセル (on_confirm を呼ばない)
    end
    settled = true
    close_window()
    if opts.on_confirm ~= nil then
      opts.on_confirm(body)
    end
  end

  local function try_close()
    if settled then
      return
    end
    local body = body_text()
    if body:match '^%s*$' then
      settled = true
      close_window()
      return
    end
    local now = now_fn()
    if armed ~= nil and now - armed.at <= DISCARD_WINDOW_S and armed.body == body then
      settled = true
      close_window() -- 明示的な破棄 (on_confirm を呼ばない)
      return
    end
    armed = { at = now, body = body }
    vim.notify(
      'review.nvim: 本文があります。確定は Normal <CR>、入力を破棄するには q をもう一度',
      vim.log.levels.WARN
    )
  end

  vim.keymap.set('n', '<CR>', confirm, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', 'q', try_close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ 'i', 'n' }, '<C-y>', confirm, { buffer = buf, nowait = true, silent = true })
  -- <Esc> はマッピングしない: insert からは暗黙に Normal へ戻るだけ (窓は残る)。

  -- 窓離脱 (:q 等) をキャンセルとして扱う確定経路。settled 済みなら何も起きない。
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      settled = true
    end,
  })

  vim.cmd 'startinsert'
end

return M
