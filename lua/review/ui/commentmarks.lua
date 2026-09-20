-- ui/commentmarks: コメントの head バッファ extmark 表示 (docs/design/features/
-- diff-review.md「コメント表示 (head バッファの extmark)」)。行下スレッド描画
-- (unified 描画の撤廃に伴い分離) を担う。対象は head 実ファイル / 縮退 scratch
-- の新側行そのもの (行写像変換は存在しない — INV-2)。
-- 真実は常に session.comments 側: apply は張った mark を捨てて再構成する。
-- 表示要素 (件数 virt_text + 行下スレッド virt_lines) は群につき 1 extmark に
-- 併合する。範囲コメントの群 (最終行で束ねる) は下線 mark と分かれるので
-- 2 mark になり、単一行コメントの 1 mark と別群の下線 mark が同一位置
-- (row, 0) に並ぶ tie は残る — そのため spec は index ではなく details
-- (virt_text ~= nil / virt_lines_above / hl_group == 'ReviewCommentLine') で
-- mark を識別する。
-- スレッドは罫線の箱で囲む (箱幅は apply 時点の opts.max_width で固定される。
-- リサイズの再 apply は handlers/session 側の WinResized / VimResized)。
-- 張ったバッファは tracked に集約し、セッション close / delete で全バッファの
-- namespace を明示 clear する (残骸 0。同バッファの全窓に見える仕様と対)。
local highlight = require 'review.ui.highlight'

local M = {}

local ns = vim.api.nvim_create_namespace 'review_comment'

-- apply したバッファ集 (~ bufnr = true)。Neovim に BufWipedout は無く
-- wipe でも BufUnload が走るため掃除の受口は BufUnload (既知の制約)。
local tracked = {}

vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    tracked[ev.buf] = nil
  end,
})

function M.ns()
  return ns
end

-- 全文 float (i) へ逃がす行下スレッドの打ち切り行数 (現行契約踏襲)。
-- 打ち切り行数は折り返しで増えた表示行も数える。
local MAX_THREAD_LINES = 10

-- 行末コメント表示と、head バッファに解けない outdated を集約する mark の hl。
local OUTDATED_HEAD_FMT = ' %d outdated (prompt 除外中)'
local COMMENT_HEAD_HL = 'ReviewPanelComment'
local OUTDATED_HEAD_HL = 'ReviewCommentOutdated'
local BODY_HL = 'ReviewCommentBody'
local BORDER_HL = 'ReviewCommentBorder'

-- 差分まるごと消滅 placeholder path (handlers/session NO_CHANGES と同一文字列)。
-- この path では「解ける行が存在しない全 outdated」(file を問わない) を集約する。
local NO_CHANGES = '(no-changes)'

-- 隣接する同色 chunk を併合する (既存契約の chunk 形 = 同色最大併合)。
local function merge_chunks(chunks)
  local out = {}
  for _, chunk in ipairs(chunks) do
    local last = out[#out]
    if last ~= nil and last[2] == chunk[2] then
      last[1] = last[1] .. chunk[1]
    else
      out[#out + 1] = { chunk[1], chunk[2] }
    end
  end
  return out
end

-- chunk 連結の表示幅。strdisplaywidth で CJK・tab・ambiwidth を Neovim 側の
-- 計算に吸収する (罫線文字も East Asian Ambiguous なので定数で数えない)。
local function chunks_width(chunks)
  local w = 0
  for _, chunk in ipairs(chunks) do
    w = w + vim.fn.strdisplaywidth(chunk[1])
  end
  return w
end

-- 横罫線。目標幅に達するまで ─ を繰り返す (ambiwidth=double で罫線文字が
-- 2 セルになるため、本数は strdisplaywidth で決める)。
local function rule_line(left, right, width)
  local s = left
  while vim.fn.strdisplaywidth(s .. '─') <= width - vim.fn.strdisplaywidth(right) do
    s = s .. '─'
  end
  return s .. right
end

-- 本文 1 行を表示幅の累積で分割する (単語境界は考慮しない)。budget nil = 上限
-- なし。各行は最低 1 文字を消費する (budget が 1 文字幅未満でも無限に切らない)。
local function wrap_body(text, budget1, budget2)
  if text == '' then
    return { '' }
  end
  local pieces = {}
  local cur, cur_w = '', 0
  local budget = budget1
  for i = 0, vim.fn.strchars(text) - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local w = vim.fn.strdisplaywidth(ch)
    if cur ~= '' and budget ~= nil and cur_w + w > budget then
      pieces[#pieces + 1] = cur
      cur, cur_w = ch, w
      budget = budget2
    else
      cur = cur .. ch
      cur_w = cur_w + w
    end
  end
  pieces[#pieces + 1] = cur
  return pieces
end

-- 1 コメントの箱の中身行 (chunk 配列の配列。罫線は含まない)。inner = 箱の
-- 内側幅 (nil = 折り返さない)。1 表示行目は id 接頭辞 / 折り返し後と 2 行目以降
-- の本文行は continuation pad を付ける (pad 幅は id 接頭辞と同じ)。
local function comment_lines(c, inner)
  local prefix = ('  [%s] '):format(c.id)
  local pad = string.rep(' ', vim.fn.strchars(prefix))
  local prefix_hl = c.state == 'outdated' and OUTDATED_HEAD_HL or BODY_HL
  local out = {}
  local truncated = false
  local blines = vim.split(c.body or '', '\n', { plain = true })
  local budget1 = inner ~= nil and inner - vim.fn.strdisplaywidth(prefix) or nil
  local budget2 = inner ~= nil and inner - vim.fn.strdisplaywidth(pad) or nil
  for i, bl in ipairs(blines) do
    if #out >= MAX_THREAD_LINES then
      truncated = true
      break
    end
    local head, head_hl
    if i == 1 then
      head, head_hl = prefix, prefix_hl
    else
      head, head_hl = pad, BODY_HL
    end
    for j, piece in ipairs(wrap_body(bl, budget1, budget2)) do
      if #out >= MAX_THREAD_LINES then
        truncated = true
        break
      end
      local h, hh
      if j == 1 then
        h, hh = head, head_hl
      else
        -- 折り返し行にも continuation pad を付ける
        h, hh = pad, BODY_HL
      end
      local chunks = { { h, hh } }
      if piece ~= '' then
        chunks[#chunks + 1] = { piece, BODY_HL }
      end
      out[#out + 1] = merge_chunks(chunks)
    end
  end
  if truncated then
    -- 打ち切り導線: pad は本文色、文言のみ警告色 (id 接頭辞と同じ扱い)。
    -- 文言も箱の中身行なので内側幅で折り返す (右辺からはみ出さない)
    for _, piece in ipairs(wrap_body('… (i で全文)', budget2, budget2)) do
      if prefix_hl == BODY_HL then
        out[#out + 1] = merge_chunks { { pad, BODY_HL }, { piece, BODY_HL } }
      else
        out[#out + 1] = { { pad, BODY_HL }, { piece, prefix_hl } }
      end
    end
  end
  return out
end

-- 箱の外幅 = 群内の行の最大表示幅 + 罫線と padding。上限 opts.max_width
-- (nil = 上限なし)、下限 20。戻り値は外幅と内側幅 (罫線 2 本と両側 padding 分を
-- 引いた幅 = 本文の pad 詰め先)。
local function box_width(sections, max_width)
  local natural = 0
  for _, lines in ipairs(sections) do
    for _, line in ipairs(lines) do
      local w = chunks_width(line)
      if w > natural then
        natural = w
      end
    end
  end
  local left = vim.fn.strdisplaywidth '│ '
  local right = vim.fn.strdisplaywidth ' │'
  local outer = math.max(20, math.min(natural + left + right, max_width or math.huge))
  return outer, outer - left - right
end

-- セクション (1 コメント分の行集合) を罫線の箱で囲む。セクション間は横罫線の
-- 区切り (旧 ' ' 空白行の置換)。各行は先頭 '│ ' (Border)、末尾に右寄せ pad
-- (Body) + ' │' (Border) を足す。pad を Border 色にしない = FloatBorder に背景色
-- がある colorscheme で pad 部分が塗られない (打ち切り行の pad 分割と同じ流儀)。
local function boxed(sections, outer, inner)
  local rows = { { { rule_line('┌', '┐', outer), BORDER_HL } } }
  for si, lines in ipairs(sections) do
    if si > 1 then
      rows[#rows + 1] = { { rule_line('├', '┤', outer), BORDER_HL } }
    end
    for _, line in ipairs(lines) do
      local pad = string.rep(' ', math.max(0, inner - chunks_width(line)))
      local chunks = { { '│ ', BORDER_HL } }
      for _, chunk in ipairs(line) do
        chunks[#chunks + 1] = chunk
      end
      chunks[#chunks + 1] = { pad, BODY_HL }
      chunks[#chunks + 1] = { ' │', BORDER_HL }
      rows[#rows + 1] = chunks
    end
  end
  rows[#rows + 1] = { { rule_line('└', '┘', outer), BORDER_HL } }
  return rows
end

--- コメントの head バッファ extmark を再構成する。
--- opts.max_width (セル数、nil = 上限なし) は箱の外幅の上限で、呼び出し側
--- (handlers/session) が head 窓のテキスト幅から算出する (commentmarks は窓を
--- 探さない = 単体 spec で幅を注入できる)。
function M.apply(session, bufnr, path, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  highlight.setup()
  tracked[bufnr] = true

  local line_count_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count_count == 0 then
    -- 0 行バッファ (追加ファイルの base scratch / 中身消失) には anchor を張れない
    -- (virt_lines を掛ける行が存在しない)。
    return
  end

  -- 前回描画を捨てて再構成 (バッファ側に真実を置かない — 現行契約)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local line_count = line_count_count
  local max_width = opts ~= nil and opts.max_width or nil
  -- 群キー = 範囲の最終行 (end_line をバッファ末尾に clamp。end_line < line の
  -- 不正値は開始行に倒す — 下線 mark の end_row < row を作らない)。
  -- in-scope 判定は開始行のまま (開始行が解けるコメントは outdated に落とさない)。
  local groups = {} -- [最終行] = { comments }
  local group_order = {}
  local outdated_hidden = {}
  for _, c in ipairs(session.comments or {}) do
    local in_scope = (path == NO_CHANGES and c.state == 'outdated') or c.file == path
    if in_scope then
      -- new 側の行番号 = head バッファの行番号そのもの (INV-2: 変換経路は無し)。
      -- 解けない (= バッファ行数を超える / placeholder) outdated は 1 行目
      -- virt_lines_above に集約する (diff-review「コメント表示」)。
      local row = path ~= NO_CHANGES and c.line or nil
      if row ~= nil and row >= 1 and row <= line_count then
        local key = math.max(row, math.min(c.end_line or row, line_count))
        local g = groups[key]
        if g == nil then
          g = {}
          groups[key] = g
          group_order[#group_order + 1] = key
        end
        g[#g + 1] = c
      elseif c.state == 'outdated' then
        outdated_hidden[#outdated_hidden + 1] = c
      end
    end
  end

  -- 群毎の描画: 件数 eol 表示 + 罫線の箱 (行下スレッド) は群につき 1 mark、
  -- 範囲コメントは下線 mark がもう 1 個 (top..bottom の 1 本)。
  for _, key in ipairs(group_order) do
    local cs = groups[key]
    local top = cs[1].line
    for _, c in ipairs(cs) do
      if c.line < top then
        top = c.line
      end
    end
    local bottom = key
    -- 打ち切り行数は折り返し行を含むため、自然幅の測定 (折り返しなし) と
    -- 実際の生成 (内側幅で折り返し) の 2 回生成する
    local natural = {}
    for _, c in ipairs(cs) do
      natural[#natural + 1] = comment_lines(c, nil)
    end
    local outer, inner = box_width(natural, max_width)
    local sections = {}
    for _, c in ipairs(cs) do
      sections[#sections + 1] = comment_lines(c, inner)
    end
    local virt_lines = boxed(sections, outer, inner)
    -- nf-cod-comment (U+EA6B)。旧 💬 は廃止 (panel アイコンと同一グリフ)。
    local text = (' \u{EA6B} %d'):format(#cs)
    local end_col = #vim.api.nvim_buf_get_lines(bufnr, bottom - 1, bottom, false)[1]
    if top == bottom then
      -- 単一行: 下線 + 件数 + スレッドの 1 mark 併合。eol anchor (start col 0) +
      -- right_gravity=true (boolean 指定) で編集時の行移動に自動追従。
      vim.api.nvim_buf_set_extmark(bufnr, ns, top - 1, 0, {
        end_row = bottom - 1,
        end_col = end_col,
        hl_group = 'ReviewCommentLine',
        virt_text = { { text, COMMENT_HEAD_HL } },
        virt_text_pos = 'eol',
        virt_lines = virt_lines,
        right_gravity = true,
      })
    else
      -- 範囲: 下線 (top..bottom の 1 本) とスレッド (最終行の下) を 2 mark に
      -- 分ける。anchor col は 0 (行末 col は o 改行で mark が新行へ飛ぶ = 実測)。
      vim.api.nvim_buf_set_extmark(bufnr, ns, top - 1, 0, {
        end_row = bottom - 1,
        end_col = end_col,
        hl_group = 'ReviewCommentLine',
        right_gravity = true,
      })
      vim.api.nvim_buf_set_extmark(bufnr, ns, bottom - 1, 0, {
        virt_text = { { text, COMMENT_HEAD_HL } },
        virt_text_pos = 'eol',
        virt_lines = virt_lines,
        right_gravity = true,
      })
    end
  end

  -- 位置を解けない outdated の集約: 当該 head バッファ 1 行目の virt_lines_above
  -- に、見出し「N outdated (prompt 除外中)」を箱 1 行目に置いた箱を描く。
  -- 見出しは eol virt_text にしない — 1 行目が実ファイルの 1 行目なので編集で
  -- 先頭に別行が足されると見出しがずれる。virt_lines_above はバッファ行に占有
  -- されず行写像も不変 (AGENTS 実測の教訓)。
  if #outdated_hidden > 0 then
    -- 見出しは箱 1 行目で、先頭 comment とは区切り罫線を挟まず隣接させる
    local function hidden_sections(inner)
      local sections = {}
      for i, c in ipairs(outdated_hidden) do
        local lines = comment_lines(c, inner)
        if i == 1 then
          table.insert(lines, 1, {
            { OUTDATED_HEAD_FMT:format(#outdated_hidden), OUTDATED_HEAD_HL },
          })
        end
        sections[#sections + 1] = lines
      end
      return sections
    end
    local outer, inner = box_width(hidden_sections(nil), max_width)
    -- virt_lines の 1 行 = chunk 配列、chunk = { text, hl } のネスト構造
    -- ({text,hl} フラットは "expected Array, got String" — AGENTS 実測の教訓)。
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_lines = boxed(hidden_sections(inner), outer, inner),
      virt_lines_above = true,
    })
  end
end

--- 張ったバッファの namespace を明示 clear (セッション close / 種別切替で
--- 実ファイル窓に残骸を残さない)。1 件でも invalid なら tracked から落とす。
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  end
  tracked[bufnr] = nil
end

function M.clear_tracked()
  for bufnr in pairs(tracked) do
    M.clear(bufnr)
  end
end

return M
