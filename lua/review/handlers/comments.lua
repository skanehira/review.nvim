-- コメント操作フロー (docs/design/features/diff-review.md「操作」c / e / d、
-- ai-prompt.md「出力経路」y、DESIGN.md「デフォルトキーマップ」)。
-- 位置の選択は **head バッファの行番号 = new 側行番号の恒等写像のみ** (INV-2)。
-- unified 自前行写像は撤廃され、窓の解決・コメント可否は
-- handlers.session が単一経路で返す (この層は行番号を計算しない)。
-- 作成・編集・削除の直後に必ず session を永続化する (INV-4。失敗時の留保は
-- handlers/session の persist が担当)。
local comment_model = require 'review.core.comment'
local prompt_handler = require 'review.handlers.prompt'
local result = require 'review.core.result'
local session_handler = require 'review.handlers.session'
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

-- head 窓解決。コメント不可 (base / 告知窓 / 縮退 placeholder) は確定 WARN 文言で
-- 弾く (DESIGN.md キー表 «この窓にはコメントを付けられません» — keygate 側の gate
-- を通ってきても直接 API 経路ではここで守る)。
local function head_target()
  local target = session_handler.comment_target()
  if target == nil then
    notify_warn 'アクティブなセッションがありません'
    return nil
  end
  if not target.commentable then
    notify_warn 'この窓にはコメントを付けられません'
    return nil
  end
  return target
end

local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1]
end

-- 選択/カーソル行 range の new 側行 (恒等)。head 窓解決できない/選択が行外なら nil。
local function new_line_range(r1, r2)
  local target = head_target()
  if target == nil then
    return nil
  end
  local lo, hi = session_handler.ident_range(r1, r2)
  if lo == nil then
    return nil
  end
  return lo, hi, target
end

-- anchor: 追加時点の新側行テキスト + 前後 1 行 (handlers.session が head
-- バッファから読む。範囲外は vim.NIL — JSON では null)。
local function anchor_for(buf, line)
  return session_handler.anchor_lines(buf, line)
end

local function create_comment(target, lo, hi, body)
  comment_model.add(target.session.comments, {
    file = target.path,
    line = lo,
    end_line = hi,
    body = body,
    anchor = anchor_for(target.buf, lo),
    created_at = now(),
  })
  session_handler.commit_comment_change()
end

-- 単独行 (c normal) と範囲選択 (c visual) で WARN の言い回しを変える。
local function add_with_range(r1, r2, single)
  local lo, hi, target = new_line_range(r1, r2)
  if target == nil then
    return
  end
  if lo == nil then
    if single then
      notify_warn 'その行にコメントを付けられません (head バッファの行范围外)'
    else
      notify_warn '選択が head バッファの行范围外です'
    end
    return
  end
  ui_input.open {
    -- どの行に対する入力かの常時表示 (UX review F16)。
    hint = lo == hi and ('%s:%d'):format(target.path, lo)
      or ('%s:%d-%d'):format(target.path, lo, hi),
    on_confirm = function(body)
      create_comment(target, lo, hi, body)
    end,
  }
end

--- `c` (normal): カーソル位置の new 側行へコメント作成。
function M.add_normal()
  add_with_range(cursor_row(), cursor_row(), true)
end

--- `c` (visual / visual-line / visual-block): 現在の選択範囲の new 側行 range。
--- expr mapping は visual mode を抜ける前に評価されることがあり、その瞬間
--- `<` `>` は未設定 — marks 依存だと初回選択の押下が無反応になる (ユーザー報告の
--- 真因: Ctrl-V で選択 -> c が沈黙、選び直すと動く)。visual/select 中は live 位置
--- (`getpos('v')` = 開始、cursor = 現在端) から行を取り、抜けた後の呼び出し
--- (:normal 駆動等) は従来どおり marks にフォールバックする。
function M.add_visual_marks()
  local lo, hi
  local m = vim.fn.mode()
  if m == 'v' or m == 'V' or m == '\22' or m == 's' or m == 'S' or m == '\19' then
    lo = vim.fn.getpos('v')[2]
    hi = vim.fn.getpos('.')[2]
  else
    lo = vim.fn.getpos("'<")[2]
    hi = vim.fn.getpos("'>")[2]
  end
  if hi < lo then
    lo, hi = hi, lo
  end
  add_with_range(lo, hi, false)
end

-- カーソル行 range に含まれるコメント一覧。該当無しは nil (e と d 共通)。
-- 行解決は恒等: cursor 行が new 側そのもの。
local function comments_at_cursor()
  local target = head_target()
  if target == nil then
    return nil
  end
  local line = cursor_row()
  if line < 1 or line > vim.api.nvim_buf_line_count(target.buf) then
    notify_warn 'その行のコメントはありません'
    return nil
  end
  local found = comment_model.find_at(target.session.comments, target.path, line)
  if #found == 0 then
    notify_warn 'その行のコメントはありません'
    return nil
  end
  return target, found
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
  local target, found = comments_at_cursor()
  if target == nil then
    return
  end

  local function do_edit(c)
    ui_input.open {
      value = c.body,
      hint = c.file
        .. ':'
        .. (c.line == c.end_line and tostring(c.line) or (c.line .. '-' .. c.end_line)),
      on_confirm = function(body)
        comment_model.update(target.session.comments, c.id, body)
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
  local target, found = comments_at_cursor()
  if target == nil then
    return
  end
  prompt_handler.for_line(target.session, found)
end

--- `i`: カーソル行範囲のコメント全文を read-only float で閲覧 (UX 提案:
--- virt_text は 40 字で切れ、編集 float は操作経路が編集なので閲覧に不向き)。
--- 対象行の path:line は表示済み。outdated は prompt 除外中である旨を添える。
function M.view_current()
  local target, found = comments_at_cursor()
  if target == nil then
    return
  end
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
    title = ' Comment ' .. (target.path or ''),
  })
end

--- `d`: カーソル行 (range 内) のコメントを arming 二重押しで削除 (状態定義は
--- ファイル冒頭側)。複数該当時は保持順の最初を対象にする。
function M.delete_current()
  local target, found = comments_at_cursor()
  if target == nil then
    return
  end
  local c = found[1]
  local t = now()
  if
    delete_armed ~= nil
    and delete_armed.ref == c
    and t - delete_armed.at <= DELETE_ARM_WINDOW_S
  then
    delete_armed = nil
    local removed = comment_model.remove(target.session.comments, c.id)
    session_handler.commit_comment_change()
    vim.notify(
      ('review.nvim: コメント %s を削除しました'):format(removed.id),
      vim.log.levels.INFO
    )
    return
  end
  delete_armed = { ref = c, at = t }
  notify_warn(
    ('コメント %s を削除するには、この行で d をもう一度 (取り消しは他行へ移動 / 2 秒待機 / <Esc> 押下)'):format(
      c.id
    )
  )
end

-- ============================================================================
-- 一括削除 (D / :Review clear)。:Review prompt でコピーし終えた後の残骸掃除用。
-- 対象は active セッションの全 comments (state 無関係 = 二度と prompt に載らない
-- outdated も一緒に消す)。コピー後の自動削除はしない — ミスコピ時に再コピーの
-- 余地を残すため、明示操作 + 確認 (キーは arming 二重押し = <Esc> でも解除、
-- コマンドは [y/N])。
-- ============================================================================

-- 個別削除の delete_armed とは別状態。arming 中は「件数の変化」で無効化する
-- (二重押しの間に加筆・削除で対象集合が変わったら 1 目やり直し = 消したくない
-- ものを消さない)。単一 delete と違い窓・行に依存しないので active のみ見る。
local delete_all_armed = nil

local function do_clear(session)
  local n = comment_model.remove_all(session.comments)
  session_handler.commit_comment_change()
  vim.notify(
    ('review.nvim: コメント全 %d 件を削除しました'):format(n),
    vim.log.levels.INFO
  )
end

function M.delete_all_arming()
  local session = session_handler.active()
  if session == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  if #session.comments == 0 then
    vim.notify('review.nvim: コメントがありません', vim.log.levels.INFO)
    return
  end
  local n = #session.comments
  local t = now()
  if
    delete_all_armed ~= nil
    and delete_all_armed.n == n
    and t - delete_all_armed.at <= DELETE_ARM_WINDOW_S
  then
    delete_all_armed = nil
    do_clear(session)
    return
  end
  delete_all_armed = { n = n, at = t }
  notify_warn(
    ('コメント全 %d 件を削除するには、もう一度押してください (取り消しは 2 秒待機 / コメントの増減 / <Esc> 押下)'):format(
      n
    )
  )
end

-- [y/N] 確認。handlers/session.confirm と同じ契約 (応答後の cmdline を空 echo で
-- 明示クリア — UX review F15)。local なのでここでも同じ形を置く。
local function confirm(prompt_text, cb)
  vim.ui.input({ prompt = prompt_text }, function(answer)
    vim.api.nvim_echo({}, false, {})
    cb(answer == 'y')
  end)
end

--- `:Review clear`。件数入りの [y/N] 確認 (0 件は確認せず INFO) の後、全 comments
--- を削除して永続化。キャンセルはセッション close の確認と同じく無通知・無変更
--- (同期戻りはディスパッチ受理)。
function M.clear_by_command()
  local session = session_handler.active()
  if session == nil then
    return result.err(
      'review.nvim: アクティブなセッションがありません',
      result.codes.E_NOT_ACTIVE
    )
  end
  if #session.comments == 0 then
    vim.notify('review.nvim: コメントがありません', vim.log.levels.INFO)
    return result.ok()
  end
  confirm(
    ('review.nvim: コメント全 %d 件を削除しますか？ (outdated も含む・削除は取り消せません) [y/N]: '):format(
      #session.comments
    ),
    function(yes)
      if yes then
        do_clear(session)
      end
    end
  )
  return result.ok()
end

--- `<Esc>`: 単一削除 (d) と一括削除 (D) の arming をまとめて解除する。解除物が
--- あったとき only INFO を出し true を返す (keygate は true のときだけキーを消費し、
--- false は built-in の <Esc> へ戻す)。一覧窓の arming は comments_list 側の別状態
--- (共有しない — comment-list「操作」)。
function M.cancel_arming()
  local had = delete_armed ~= nil or delete_all_armed ~= nil
  delete_armed = nil
  delete_all_armed = nil
  if not had then
    return false
  end
  vim.notify('review.nvim: 削除の arming を解除しました', vim.log.levels.INFO)
  return true
end

return M
