-- <F1> help float (diff-review.md「操作」)。表示内容は config.keymaps の現在値から
-- 生成する (DESIGN.md「API 一覧」の正本表を setup で変えたユーザーに実キーを見せる)。
-- config.keymaps のキーは実装済みのものすべて載せる (載っていないキーは
-- help に載って押せないキーを作るため追加禁止)。q / <Esc> で閉じる。
local config = require 'review.config'

local M = {}

-- 表示する (config キー, 説明)。Diff review「操作」表の範囲コメント含む説明。
local SECTIONS = {
  {
    title = 'diff バッファ',
    keymap = 'diff',
    rows = {
      { 'add_comment', '作成コメント (visual-line で範囲指定)' },
      { 'edit_comment', 'カーソル行のコメントを編集' },
      {
        'delete_comment',
        'カーソル行のコメントを削除 (arming: 同じ行でもう一度 d)',
      },
      { 'yank_prompt', 'カーソル行のコメントのプロンプトを yank' },
      { 'open_file', 'その行の実ファイルを開く' },
      { 'close', 'セッションを閉じる' },
      { 'help', 'このヘルプ' },
      { 'next_file', '次のファイルへ (端では無動作)' },
      { 'prev_file', '前のファイルへ (端では無動作)' },
      { 'focus_sidebar', 'sidebar (変更ファイル一覧) へ移動' },
      { 'view_comments', 'カーソル行のコメントを閲覧 (read-only)' },
    },
  },
  {
    title = 'sidebar (変更ファイル一覧)',
    keymap = 'sidebar',
    rows = {
      { 'open_diff', 'そのファイルの diff へ移動' },
      { 'open_file', 'そのファイルの実ファイルを開く' },
      { 'toggle_viewed', 'viewed 切替' },
      { 'close', 'セッションを閉じる' },
    },
  },
  {
    title = 'セッション一覧 (:Review list)',
    keymap = 'sessionlist',
    rows = {
      { 'open', '選択セッションを開く' },
      { 'close', '一覧を閉じる (セッション状態は変えない)' },
      { 'delete', '選択セッションを削除 (:Review delete と同じ確認)' },
    },
  },
  {
    -- コメント入力 float のキーは config.keymaps 対象外 (固定)。確定/閉じるの
    -- 操作は discoverability の中心なので help に載せる (窓 title にも常時表示)。
    title = 'コメント入力 (c/e で開く)',
    keymap = nil,
    rows = {
      { '<CR>', '確定 (Normal)。insert 中の <CR> は改行' },
      {
        'q',
        '閉じる。本文なし=キャンセル / 本文ありは閉じず、続けて q で破棄',
      },
      { '<C-y>', '確定 (insert)' },
      { '<Esc>', 'Normal へ戻るだけ (窓は閉じない)' },
    },
  },
}

function M.open()
  local keymaps = config.get().keymaps
  local lines = { 'review.nvim キーバインド' }
  for _, section in ipairs(SECTIONS) do
    table.insert(lines, '')
    table.insert(lines, '[' .. section.title .. ']')
    for _, row in ipairs(section.rows) do
      local key = section.keymap and keymaps[section.keymap][row[1]] or row[1]
      table.insert(lines, key .. ' ' .. row[2])
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = 4
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(20, math.min(76, width + 2))
  local height = math.max(4, math.min(vim.o.lines - 2, #lines + 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = 'rounded',
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  -- <F1> 相当の再トグルは不要 (help 自身は help キーを貼らない)。
  vim.keymap.set({ 'n', 'i' }, 'q', close, { buffer = buf, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<Esc>', close, { buffer = buf, nowait = true })
end

return M
