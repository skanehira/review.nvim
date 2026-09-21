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
    title = 'レビュー窓 (head / base)',
    keymap = 'diff',
    rows = {
      { 'add_comment', '作成コメント (visual-line で範囲指定・head 窓のみ)' },
      { 'edit_comment', 'カーソル行のコメントを編集 (head 窓のみ)' },
      {
        'delete_comment',
        'カーソル行のコメントを削除 (arming: 同じ行でもう一度 d)',
      },
      {
        'delete_all',
        '全コメントを一括削除 (arming: もう一度押す。:Review clear と同じ)',
      },
      {
        'cancel_arming',
        'd / D の arming 解除 (arming 中でないときは built-in の <Esc>)',
      },
      { 'yank_prompt', 'カーソル行のコメントのプロンプトを yank' },
      { 'close', 'セッションを閉じる (レビュー tab を閉じる)' },
      { 'help', 'このヘルプ (g? でも開く)' },
      { 'next_file', '次のファイルへ (端では無動作)' },
      { 'prev_file', '前のファイルへ (端では無動作)' },
      { 'first_file', '最初のファイルへ' },
      { 'last_file', '最後のファイルへ' },
      { 'refresh', '差分を再取得 (リフレッシュ)' },
      { 'focus_panel', 'file panel (変更ファイル一覧) へ移動' },
      {
        'toggle_panel',
        'file panel の表示トグル (閉じても tab とレビュー窓は残る)',
      },
      {
        'comments_list',
        'コメント一覧 (横断) をレビュー tab の最下部に全幅で開く (:Review comments と同じ。既に開いていればその窓へ focus)',
      },
      { 'view_comments', 'カーソル行のコメントを閲覧 (read-only)' },
    },
  },
  {
    title = 'file panel (変更ファイル一覧)',
    keymap = 'sidebar',
    rows = {
      {
        'open_diff',
        'そのファイルを head/base 窓に開く (カーソルは file panel に残る。dir 行では折り畳み)',
      },
      { 'open_file', '<CR> と同じ (file panel の o = entry を開く)' },
      { 'open_entry', '<CR> と同じ (entry を開く)' },
      -- 移動系・refresh の文案は doc/review.txt sidebar 節と同文。diff 節と同一文に
      -- すると help_spec の has_line 完全一致が節を区別できず (検出能力ゼロ)、
      -- 節の行数が減ってもテストが緑になる。文言を一意化している。
      {
        'next_file',
        '次のファイル (file panel の表示順 = <CR> と同一処理。focus も panel に残る。端は無動作)',
      },
      { 'prev_file', '前のファイル (上記と同じ規則)' },
      { 'first_file', '最初のファイル (上記と同じ規則)' },
      { 'last_file', '最後のファイル (上記と同じ規則)' },
      { 'refresh', '差分を再取得 (レビュー窓の R と同一)' },
      { 'toggle_style', 'list 表示 (フルパス 1 行) ⇄ tree 表示を切替' },
      { 'toggle_viewed', 'レビュー完了マーク [✓] 切替 (open では付かない)' },
      { 'filter', '一覧を絞り込む (空入力で解除)' },
      { 'help', 'このヘルプ (file panel でも g? で開く)' },
      { 'close', 'セッションを閉じる' },
      { 'comments_list', 'コメント一覧 (横断) を開く (diff 窓と同じ)' },
    },
  },
  {
    title = 'コメント一覧 (横断)',
    keymap = 'commentlist',
    rows = {
      { 'jump', 'カーソル行のコメント位置へジャンプ' },
      {
        'delete',
        'カーソル行のコメントを削除 (一覧専用 arming: 同じ行でもう一度 d)',
      },
      {
        'delete_all',
        '全コメントを一括削除 (一覧専用 arming: もう一度押す。:Review clear と同じ)',
      },
      {
        'cancel_arming',
        'd / D の一覧 arming を解除 (解除物が無ければ無動作)',
      },
      { 'edit', 'カーソル行のコメントを編集' },
      { 'yank', 'カーソル行のコメントのプロンプトを yank' },
      { 'close', '一覧を閉じる (セッション状態は変えない)' },
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
  {
    -- DESIGN 決定表 «gate 不成立窓では 1 キーストロークが built-in になる副作用
    -- は user doc (help) に明記» の help float 側文案 (doc/review.txt と同文)。
    title = '注記',
    keymap = nil,
    rows = {
      {
        '注:',
        'レビュー窓のキーは buffer-local + 押下時点の窓 role gate。gate を通らない窓 '
          .. '(ユーザーが自分の窓で開いた同じ実ファイルなど) では 1 キーストロークが '
          .. 'built-in 動作に戻る',
      },
    },
  },
}

function M.open()
  local keymaps = config.get().keymaps
  -- markdown ソース (## 見出し + `- **キー** 説明`)。キーは config の現在値。
  local lines = { '# review.nvim キーバインド', '' }
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
