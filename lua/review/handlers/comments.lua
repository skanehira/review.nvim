-- コメント操作フロー (docs/design/features/diff-review.md「操作」c / e / d、
-- ai-prompt.md「出力経路」y)。位置の選択 (new 側行番号) は diffbuffer の行写像経由のみ
-- — 行番号の独自計算をしない (DESIGN.md「既知の制約」)。作成・編集・削除の直後に必ず
-- session を永続化する (INV-4。失敗時の留保は handlers/session の persist が担当)。
local comment_model = require 'review.core.comment'
local prompt_handler = require 'review.handlers.prompt'
local session_handler = require 'review.handlers.session'
local ui_diffbuffer = require 'review.ui.diffbuffer'
local ui_input = require 'review.ui.input'
local ui_view = require 'review.ui.commentview'

local M = {}

local now = os.time

function M._set_now(fn)
  now = fn or os.time
end

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

-- 現在のバッファが対象の diff かを照らし、(session, bufnr, path) を返す。
local function diff_target()
  local session = session_handler.active()
  if session == nil then
    notify_warn 'アクティブなセッションがありません'
    return nil
  end
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'diff' then
    notify_warn 'diff バッファではありません'
    return nil
  end
  return session, buf, meta.path
end

local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1]
end

-- r1..r2 の new 側行番号の min/max。全行が new 側でなければ nil (削除専用行)。
local function new_line_range(buf, r1, r2)
  local lo, hi = nil, nil
  for r = r1, r2 do
    local line = ui_diffbuffer.new_line_at(buf, r)
    if line ~= nil then
      lo = lo == nil and line or math.min(lo, line)
      hi = hi == nil and line or math.max(hi, line)
    end
  end
  return lo, hi
end

-- anchor: 追加時点の新側行テキスト + 前後 1 行。差分に可視でない行は nil (JSON
-- では null — vim.NIL を明示代入しないと encode でキーごと落ちる)。
-- 復元検証 (persistence-restore「anchor 検証」) が照らすのは line のみだが、
-- before / after はスキーマ契約として保持する。
local function anchor_for(buf, line)
  local function text(l)
    local t = ui_diffbuffer.new_side_text(buf, l)
    return t ~= nil and t or vim.NIL
  end
  return { before = text(line - 1), line = text(line), after = text(line + 1) }
end

local function create_comment(session, buf, path, lo, hi, body)
  comment_model.add(session.comments, {
    file = path,
    line = lo,
    end_line = hi,
    body = body,
    anchor = anchor_for(buf, lo),
    created_at = now(),
  })
  session_handler.commit_comment_change()
end

-- 単独行 (c normal) と範囲選択 (c visual) で WARN の言い回しを変える。
local function add_with_range(r1, r2, single)
  local session, buf, path = diff_target()
  if session == nil then
    return
  end
  local lo, hi = new_line_range(buf, r1, r2)
  if lo == nil then
    if single then
      notify_warn 'この行は new 側に存在しないためコメントを付けられません (削除行 / diff ヘッダ)'
    else
      notify_warn '選択に new 側行がありません'
    end
    return
  end
  ui_input.open {
    -- どの行に対する入力かの常時表示 (UX review F16)。
    hint = lo == hi and ('%s:%d'):format(path, lo) or ('%s:%d-%d'):format(path, lo, hi),
    on_confirm = function(body)
      create_comment(session, buf, path, lo, hi, body)
    end,
  }
end

--- `c` (normal): カーソル位置の new 側行へコメント作成。
function M.add_normal()
  add_with_range(cursor_row(), cursor_row(), true)
end

--- `c` (visual-line): '< -> '> の範囲 (marks から読む — :normal 駆動でも同じ)。
function M.add_visual_marks()
  add_with_range(vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2], false)
end

-- カーソル行 range に含まれるコメント一覧。該当無しは nil (e と d 共通)。
local function comments_at_cursor()
  local session, buf = diff_target()
  if session == nil then
    return nil
  end
  local meta = vim.b[buf].review_meta
  local line = ui_diffbuffer.new_line_at(buf, cursor_row())
  local found = line ~= nil and comment_model.find_at(session.comments, meta.path, line) or {}
  if #found == 0 then
    notify_warn 'その行のコメントはありません'
    return nil
  end
  return session, found
end

-- 削除 arming の状態 (M.delete_current が消费)。edit より前に置く: do_edit の
-- on_confirm closure から upvalue として見える位置が必要 (後方宣言だと global
-- に化けて解除が効かない)。UX review F9: vim 筋 dd が「d 2 回」= 無確認に複数件
-- 消せた事故の再発防止。入力 float の q 破棄と同じ「同じ対象・待機窓内 2 回」で
-- 確定し、「他行移動」「編集確定」「2 秒経過」で解除される。armed は object 参照
-- 比較なので、削除・再作成・選択切替で自動的に無効化する。
local DELETE_ARM_WINDOW_S = 2.0
local delete_armed = nil

--- `e`: カーソル行のコメントを編集 (複数なら vim.ui.select で対象を選ぶ)。
function M.edit_current()
  local session, found = comments_at_cursor()
  if session == nil then
    return
  end

  local function do_edit(c)
    ui_input.open {
      value = c.body,
      hint = c.file
        .. ':'
        .. (c.line == c.end_line and tostring(c.line) or (c.line .. '-' .. c.end_line)),
      on_confirm = function(body)
        comment_model.update(session.comments, c.id, body)
        session_handler.commit_comment_change()
        -- comment_model.update は同一 table を書き換える (armed ref と object
        -- 一致が続く) ため、契約どおり明示解除する。
        delete_armed = nil
      end,
    }
  end

  if #found == 1 then
    do_edit(found[1])
    return
  end
  vim.ui.select(found, {
    prompt = '編集するコメント:',
    format_item = function(c)
      return ('[%s] %s'):format(c.id, c.body)
    end,
  }, function(choice)
    if choice ~= nil then
      do_edit(choice)
    end
  end)
end

--- `y`: カーソル行 range に含まれるコメントのプロンプト (見出しなし) を
--- "0 (+クリップボード) へコピー。outdated は既定除外、全件 outdated は拒否 INFO
--- (ai-prompt.md「出力経路」y — 構築とコピーは handlers/prompt)。
function M.yank_current()
  local session, found = comments_at_cursor()
  if session == nil then
    return
  end
  prompt_handler.for_line(session, found)
end

--- `i`: カーソル行範囲のコメント全文を read-only float で閲覧 (UX 提案:
--- virt_text は 40 字で切れ、編集 float は操作経路が編集なので閲覧に不向き)。
--- 対象行の path:line は表示済み。outdated は prompt 除外中である旨を添える。
function M.view_current()
  local session, found = comments_at_cursor()
  if session == nil then
    return
  end
  local meta = vim.b[vim.api.nvim_get_current_buf()].review_meta or {}
  local lines = {}
  for i, c in ipairs(found) do
    local loc = ('%s:%d'):format(c.file, c.line)
    if (c.end_line or c.line) > c.line then
      loc = loc .. '-' .. c.end_line
    end
    local flag = c.state == 'outdated' and '  ! outdated (prompt 除外中)' or ''
    lines[#lines + 1] = ('[%d] %s  %s%s'):format(i, c.id, loc, flag)
    for _, body_line in ipairs(vim.split(c.body, '\n', { plain = true })) do
      lines[#lines + 1] = '  ' .. body_line
    end
  end
  ui_view.open(lines, {
    title = ' Comment ' .. (meta.path or ''),
  })
end

--- `d`: カーソル行 (range 内) のコメントを arming 二重押しで削除 (状態定義は
--- ファイル冒頭側)。複数該当時は保持順の最初を対象にする。
function M.delete_current()
  local session, found = comments_at_cursor()
  if session == nil then
    return
  end
  local target = found[1]
  local t = now()
  if
    delete_armed ~= nil
    and delete_armed.ref == target
    and t - delete_armed.at <= DELETE_ARM_WINDOW_S
  then
    delete_armed = nil
    local removed = comment_model.remove(session.comments, target.id)
    session_handler.commit_comment_change()
    vim.notify(
      ('review.nvim: コメント %s を削除しました'):format(removed.id),
      vim.log.levels.INFO
    )
    return
  end
  delete_armed = { ref = target, at = t }
  notify_warn(
    ('コメント %s を削除するには、この行で d をもう一度 (取り消しは他行へ移動か 2 秒待機)'):format(
      target.id
    )
  )
end

return M
