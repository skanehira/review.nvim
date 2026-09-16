-- ui/commentmarks: コメントの head バッファ extmark 表示 (docs/design/features/
-- diff-review.md「コメント表示 (head バッファの extmark)」)。行下スレッド描画
-- (unified 描画の撤廃に伴い分離) を担う。対象は head 実ファイル / 縮退 scratch
-- の新側行そのもの (行写像変換は存在しない — INV-2)。
-- 真実は常に session.comments 側: apply は張った mark を捨てて再構成する。
-- 見出し eol 件数と行下スレッドは同一 anchors に mark を二つ作ると取得順が
-- 不定になるため 1 extmark に併合する (AGENTS「実測の教訓」)。
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
local MAX_THREAD_LINES = 10

-- head バッファに解けない outdated を集約する mark の見出し文言。
local OUTDATED_HEAD_FMT = ' ⚠ %d outdated (prompt 除外中)'
local OUTDATED_HEAD_HL = 'Comment'

-- 差分まるごと消滅 placeholder path (handlers/session NO_CHANGES と同一文字列)。
-- この path では「解ける行が存在しない全 outdated」(file を問わない) を集約する。
local NO_CHANGES = '(no-changes)'

function M.apply(session, bufnr, path)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  highlight.setup()
  tracked[bufnr] = true

  local line_count_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count_count == 0 then
    -- 0 行バッファ (null scratch / 中身消失) には anchor を張れない
    -- (virt_lines を掛ける行が存在しない)。
    return
  end

  -- 前回描画を捨てて再構成 (バッファ側に真実を置かない — 現行契約)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local line_count = line_count_count
  local groups = {} -- [line] = { comments = {}, anchors = {} }
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
        local g = groups[row]
        if g == nil then
          g = {}
          groups[row] = g
          group_order[#group_order + 1] = row
        end
        g[#g + 1] = c
      elseif c.state == 'outdated' then
        outdated_hidden[#outdated_hidden + 1] = c
      end
    end
  end

  -- 行下スレッド行の生成 (見出し行 + continuation)。outdated の本文行は
  -- ReviewCommentOutdated で gray に寄せる (highlight.lua の命名)。
  local function thread_lines(c)
    local out = {}
    local prefix = c.state == 'outdated' and ('⚠ [%s] '):format(c.id) or ('  [%s] '):format(c.id)
    local pad = string.rep(' ', vim.fn.strchars(prefix))
    local hl = c.state == 'outdated' and 'ReviewCommentOutdated' or 'ReviewCommentBody'
    local blines = vim.split(c.body, '\n', { plain = true })
    for i, bl in ipairs(blines) do
      if i > MAX_THREAD_LINES then
        out[#out + 1] = { { pad .. '… (i で全文)', hl } }
        break
      end
      out[#out + 1] = { { (i == 1 and prefix or pad) .. bl, hl } }
    end
    return out
  end

  local function group_thread(comments)
    local acc = {}
    for _, c in ipairs(comments) do
      local t = thread_lines(c)
      for i = 1, #t do
        if i == 1 and #acc > 0 then
          acc[#acc + 1] = { { ' ', 'ReviewCommentBody' } }
        end
        acc[#acc + 1] = t[i]
      end
    end
    return acc
  end

  -- 群毎に 1 extmark: 見出し virt_text (件数 / outdated 混在は (⚠M)) と
  -- 行下スレッド virt_lines を併合する。eol anchor (end_col 指定なし start col
  -- 対応) + right_gravity=true (boolean 指定) で編集時の行移动に自動追従。
  for _, row in ipairs(group_order) do
    local cs = groups[row]
    local n_out = 0
    for _, c in ipairs(cs) do
      if c.state == 'outdated' then
        n_out = n_out + 1
      end
    end
    -- nf-cod-comment (U+EA6B)。旧 💬 は廃止 (panel アイコンと同一グリフ)。
    local text = (' \u{EA6B} %d'):format(#cs) .. (n_out > 0 and (' (⚠%d)'):format(n_out) or '')
    local underline_end = row
    for _, c in ipairs(cs) do
      local er = math.min(c.end_line or c.line, line_count)
      if er > underline_end then
        underline_end = er
      end
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_row = underline_end - 1,
      end_col = #vim.api.nvim_buf_get_lines(bufnr, underline_end - 1, underline_end, false)[1],
      hl_group = 'ReviewCommentLine',
      virt_text = { { text, OUTDATED_HEAD_HL } },
      virt_text_pos = 'eol',
      virt_lines = group_thread(cs),
      right_gravity = true,
    })
  end

  -- 位置を解けない outdated の集約: 当該 head バッファ 1 行目の virt_lines_above
  -- に「⚠ N outdated (prompt 除外中)」見出し行 + 本文一覧を並べる
  -- (diff-review「コメント表示」)。見出しは eol virt_text にしない — 1 行目が
  -- 実ファイルの 1 行目なので編集で先頭に別行が足されると見出しがずれる。
  -- virt_lines_above はバッファ行に占有されず行写像も不変 (AGENTS 実測の教訓)。
  if #outdated_hidden > 0 then
    -- virt_lines の 1 行 = chunk 配列、chunk = { text, hl } のネスト構造
    -- ({text,hl} フラットは "expected Array, got String" — AGENTS 実測の教訓)。
    local acc = { { { OUTDATED_HEAD_FMT:format(#outdated_hidden), OUTDATED_HEAD_HL } } }
    local body = group_thread(outdated_hidden)
    for i = 1, #body do
      acc[#acc + 1] = body[i]
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_lines = acc,
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
