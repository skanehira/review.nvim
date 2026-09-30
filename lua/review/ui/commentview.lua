-- 行コメント一覧の read-only float (diff `i` / diff-review.md「操作」)。
-- 編集用 float (ui/input) は入力を伴うため閲覧に使いにくい (本文は 40 字で
-- 切り詰められ、編集中に誤って確定/破棄の操作経路に入ってしまう)。ここでは
-- 全文・状態・位置をそのまま見せるだけを見せる (編集は `e`)。
-- 閲覧専用なので editor 中央に大きめの float を開く (本文を切らずに読む)。
--
-- 罫線は nvim の float border (`border='rounded'` + title) を使う。border は
-- window が描く固定要素なので、中身が窓高を超えても枠は動かず buffer だけが
-- スクロールする。buffer に罫線文字を置かないため、カーソルが罫線に乗ることも無い。
-- コメント間の区切りを端から端の `├─┤` にすることは nvim border ではできない
-- (左右の辺は全行共通で行ごとの制御が無い。左右を空文字にすると角が欠ける —
-- PTY 実測) ため、区切りは内容幅いっぱいの `─` 罫線行にする (左右は border の
-- `│` がそのまま残り `│──────│` に見える)。
local M = {}

-- `─` を目標表示幅まで並べる (本数は strdisplaywidth で決める。ambiwidth=double
-- で罫線文字が 2 セルになる環境でも右辺からはみ出さない)。
local function rule_fill(width)
  local s = ''
  while vim.fn.strdisplaywidth(s .. '─') <= width do
    s = s .. '─'
  end
  return s
end

-- 本文 1 行を表示幅の累積で分割する (単語境界は考慮しない)。空行は空行 1 行の
-- まま残す (コメント本文の空行を消さない)。
local function wrap_line(text, budget)
  if text == '' then
    return { '' }
  end
  local pieces = {}
  local cur, cur_w = '', 0
  for i = 0, vim.fn.strchars(text) - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local w = vim.fn.strdisplaywidth(ch)
    if cur ~= '' and cur_w + w > budget then
      pieces[#pieces + 1] = cur
      cur, cur_w = '', 0
    end
    cur = cur .. ch
    cur_w = cur_w + w
  end
  if cur ~= '' then
    pieces[#pieces + 1] = cur
  end
  return pieces
end

--- lines = 整形済み表示行 (呼び出し側 = handlers/comments。`─` 1 文字 =
--- コメント間の区切り sentinel)。opts = { title? }。
--- 窓は `q` / `<Esc>` / `<CR>` 等の単打で閉じる (modifiable=false、操作は閉じるのみ)。
--- 戻り値は window (spec 用。呼び出し側は使わない)。
function M.open(lines, opts)
  opts = opts or {}

  -- editor 中央・大きめ (スクリーンよりはみ出さないよう columns / lines で上限)。
  -- width / height は border の内側 (本文) のサイズ。
  local max_w = math.max(20, vim.o.columns - 4)
  local max_h = math.max(4, vim.o.lines - 2)
  local width = math.min(max_w, math.max(80, math.min(200, max_w)))
  local height = math.min(max_h, math.max(12, #lines + 8))

  -- 中身行: `─` sentinel は内容幅いっぱいの区切り罫線。それ以外はメタデータ行 /
  -- 本文行 (左寄せ)。長い行は内容幅で折り返し、右辺は pad で揃える。buffer には
  -- 罫線の左右辺を置かない (border が描く)。区切り行は後段で罫線色にする。
  local rows, rules = {}, {}
  for _, line in ipairs(lines) do
    if line == '─' then
      rows[#rows + 1] = rule_fill(width)
      rules[#rules + 1] = true
    else
      for _, piece in ipairs(wrap_line(line, width)) do
        rows[#rows + 1] = piece
          .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(piece)))
        rules[#rules + 1] = false
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  -- 可視サイズ = border を含めた外寸 (width + 2) x (height + 2) を中央に置く。
  local row = math.max(0, math.floor((vim.o.lines - (height + 2)) / 2))
  local col = math.max(0, math.floor((vim.o.columns - (width + 2)) / 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    border = 'rounded',
    title = (opts.title or ' Comments') .. ' q close ',
    title_pos = 'left',
  })
  -- 背景は透過 (ReviewCommentView = bg NONE。コメントスレッドと同じく塗らない)。
  -- 中身は組み立て済みで必ず内容幅に収まる (表示折り返しが起きない)。
  vim.wo[win].winhighlight = 'Normal:ReviewCommentView'
  vim.wo[win].wrap = false

  -- 区切り罫線行だけ罫線色にする (中身の文字は winhighlight の
  -- Normal → ReviewCommentView のまま)。
  local hl_ns = vim.api.nvim_create_namespace 'review-commentview'
  for i, is_rule in ipairs(rules) do
    if is_rule then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, 'FloatBorder', i - 1, 0, -1)
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  -- 閉じる操作のみ受け付ける (x/d など diff 側の意味を持つキーは閉じ方も含め
  -- どこにも効かせない = 誤操作の入口を作らない)
  for _, key in ipairs { 'q', '<Esc>', '<CR>' } do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, silent = true })
  end

  return win
end

return M
