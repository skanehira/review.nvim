-- <F1> / g? help float (diff-review.md「操作」)。表示内容は config.keymaps の現在値
-- から生成する (DESIGN.md「API 一覧」の正本表を setup で変えたユーザーに実キーを
-- 見せる)。config.keymaps のキーは実装済みのものすべて載せる (載っていないキーは
-- help に載って押せないキーを作るため追加禁止)。q / <Esc> で閉じる。
-- 内容は markdown (見出し + キーを bold の箇条書き) として組み立て、buffer は
-- filetype=markdown + conceallevel=3 で描く (markdown 装飾子は conceal で消え、
-- bold のキーだけが見える)。g? は <F1> と同一の呼び出し (固定の別名)。
local config = require 'review.config'

local M = {}

-- 表示する (config キー, 説明)。DESIGN.md「デフォルトキーマップ」の review 窓 /
-- file panel / sessionlist の全キーを載せる (説明も「head 窓のみ」等の窓条件まで)。
local SECTIONS = {
  {
    title = 'review windows (head / base)',
    keymap = 'diff',
    rows = {
      { 'add_comment', 'create a comment (visual-line for range; head window only)' },
      { 'edit_comment', 'edit the comment on the cursor line (head window only)' },
      {
        'delete_comment',
        'delete the comment on the cursor line (arming: press d again on the same line)',
      },
      {
        'delete_all',
        'delete all comments at once (arming: press again; same as :Review clear)',
      },
      {
        'cancel_arming',
        'cancel d / D arming (falls back to built-in <Esc> when not armed)',
      },
      { 'yank_prompt', 'yank the prompt of the comment on the cursor line' },
      { 'close', 'close the session (closes the review tab)' },
      { 'help', 'this help (also opens with g?)' },
      { 'next_file', 'next file (no-op at the edges)' },
      { 'prev_file', 'previous file (no-op at the edges)' },
      { 'first_file', 'first file' },
      { 'last_file', 'last file' },
      { 'refresh', 'refresh the diff' },
      { 'focus_panel', 'go to the file panel (changed files)' },
      {
        'toggle_panel',
        'toggle the file panel (closing keeps the tab and review windows)',
      },
      {
        'comments_list',
        'open the comments list (cross-file) full-width at the bottom '
          .. 'of the review tab (same as :Review comments; focuses the '
          .. 'window if already open)',
      },
      { 'view_comments', 'view the comment on the cursor line (read-only)' },
    },
  },
  {
    title = 'file panel (changed files)',
    keymap = 'sidebar',
    rows = {
      {
        'open_diff',
        'open the file in the head/base windows (cursor stays in the panel; dir rows toggle fold)',
      },
      { 'open_file', 'same as <CR> (panel o opens the entry)' },
      { 'open_entry', 'same as <CR> (open the entry)' },
      -- 移動系・refresh の文案は doc/review.txt sidebar 節と同文。diff 節と同一文に
      -- すると help_spec の has_line 完全一致が節を区別できず (検出能力ゼロ)、
      -- 節の行数が減ってもテストが緑になる。文言を一意化している。
      {
        'next_file',
        'next file (panel display order = same handling as <CR>; focus '
          .. 'stays in panel; no-op at edges)',
      },
      { 'prev_file', 'previous file (same rule as above)' },
      { 'first_file', 'first file (same rule as above)' },
      { 'last_file', 'last file (same rule as above)' },
      { 'refresh', 'refresh the diff (same as R in review windows)' },
      { 'toggle_style', 'toggle list view (full path 1 line) / tree view' },
      { 'toggle_viewed', 'toggle review-done mark [✓] (open never sets it)' },
      { 'filter', 'filter the list (empty input clears)' },
      { 'help', 'this help (g? also works in the panel)' },
      { 'close', 'close the session' },
      { 'comments_list', 'open the comments list (same as the diff windows)' },
    },
  },
  {
    title = 'comments list (cross-file)',
    keymap = 'commentlist',
    rows = {
      { 'jump', 'jump to the comment on the cursor line' },
      {
        'delete',
        'delete the comment on the cursor line (list-only arming: press d again on the same line)',
      },
      {
        'delete_all',
        'delete all comments at once (list-only arming: press again; same as :Review clear)',
      },
      {
        'cancel_arming',
        'cancel list d / D arming (no-op when nothing is armed)',
      },
      { 'edit', 'edit the comment on the cursor line' },
      { 'yank', 'yank the prompt of the comment on the cursor line' },
      { 'close', 'close the list (leaves the session state unchanged)' },
    },
  },
  {
    title = 'sessions list (:Review list)',
    keymap = 'sessionlist',
    rows = {
      { 'open', 'open the selected session' },
      { 'close', 'close the list (leaves the session state unchanged)' },
      { 'delete', 'delete the selected session (same confirm as :Review delete)' },
    },
  },
  {
    -- コメント入力 float のキーは config.keymaps 対象外 (固定)。確定/閉じるの
    -- 操作は discoverability の中心なので help に載せる (窓 title にも常時表示)。
    title = 'comment input (opened by c/e)',
    keymap = nil,
    rows = {
      { '<CR>', 'confirm (Normal). <CR> in insert is a newline' },
      {
        'q',
        'close. empty body cancels; with body it stays open, press q again to discard',
      },
      { '<C-y>', 'confirm (insert)' },
      { '<Esc>', 'return to Normal only (does not close)' },
    },
  },
  {
    -- DESIGN 決定表 «gate 不成立窓では 1 キーストロークが built-in になる副作用
    -- は user doc (help) に明記» の help float 側文案 (doc/review.txt と同文)。
    title = 'note',
    keymap = nil,
    rows = {
      {
        'note:',
        'review keys are buffer-local with a window role gate at press time. windows that fail '
          .. 'the gate (e.g. the same real file opened in your own window) fall back 1 keystroke '
          .. 'to built-in behavior',
      },
    },
  },
}

function M.open()
  local keymaps = config.get().keymaps
  -- markdown ソース (## 見出し + `- **キー** 説明`)。キーは config の現在値。
  local lines = { '# review.nvim keymap', '' }
  for _, section in ipairs(SECTIONS) do
    table.insert(lines, '## ' .. section.title)
    for _, row in ipairs(section.rows) do
      local key = section.keymap and keymaps[section.keymap][row[1]] or row[1]
      table.insert(lines, ('- **%s** %s'):format(key, row[2]))
    end
    table.insert(lines, '')
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- markdown として描く (装飾は conceal。raw の `##` / `**` は見せない)
  vim.bo[buf].filetype = 'markdown'

  local width = 4
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(20, math.min(76, width + 2))
  -- wrap 表示の折返し込みで高さを出す (長い説明行を切らない)
  local height = 0
  for _, line in ipairs(lines) do
    local disp = vim.fn.strdisplaywidth(line)
    height = height + math.max(1, math.ceil(disp / width))
  end
  height = math.max(4, math.min(vim.o.lines - 2, height + 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = 'rounded',
  })
  vim.wo[win].conceallevel = 3
  vim.wo[win].concealcursor = 'n'
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

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
