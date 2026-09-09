-- コピー先解決とプロンプト出力の調整役 (docs/design/features/ai-prompt.md
-- 「出力経路」「エッジケースの決定」)。整形は core/prompt の純関数に置き、
-- ここは active セッション解決・空/outdated の通知・レジスタ/クリップボード書き込みのみ担う。
-- クリップボード provider の検出はこのランタイムの観測可能な定義 (下記 has_provider)。
local core_prompt = require 'review.core.prompt'
local result = require 'review.core.result'
local session_handler = require 'review.handlers.session'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

local function notify_info(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.INFO)
end

--- クリップボード provider の有無。ai-prompt.md は `clipboard.provider()` を挙げるが
--- nvim 0.13-nightly 実機では該当 Lua API が存在しない (DESIGN.md「既知の制約」)。
--- :help clipboard-provider の定義経路 (g:clipboard テーブル / clipboard#copy autoload)
--- と、将来ビルドの clipboard.provider() を検査する。
function M.has_provider()
  if type(vim.g.clipboard) == 'table' then
    return true
  end
  if vim.fn.exists '*clipboard#copy' == 1 then
    return true
  end
  local ok, clipboard = pcall(require, 'clipboard')
  return ok
    and type(clipboard) == 'table'
    and type(clipboard.provider) == 'function'
    and clipboard.provider() ~= nil
end

--- text を常時 "0 へ、provider があれば +/* にもコピーする。
--- provider 無子は WARN して "0 のみ (ai-prompt.md 退路。失敗で止めない)。
local function copy_text(text)
  vim.fn.setreg('0', text)
  if not M.has_provider() then
    notify_warn 'クリップボード provider がありません。"0 レジスタにのみコピーしました'
    return
  end
  -- nvim 0.13-nightly 実機: setreg の第 1 引数 List は E730 (既知の制約)。個別に書く。
  vim.fn.setreg('+', text)
  vim.fn.setreg('*', text)
end

local function table_or_nil(v)
  return type(v) == 'table' and v or nil
end

-- session -> core_prompt の ctx スキーマ。worktree あり = 絶対 path、pr = 見出し書式
-- (ai-prompt.md「パスの規則」「見出し行」)。
local function ctx_for(session)
  local worktree = table_or_nil(session.worktree)
  return {
    mode = session.mode,
    base = session.base,
    head = session.head,
    pr = table_or_nil(session.pr),
    worktree_path = worktree and worktree.path or nil,
  }
end

-- 構築 + コピー共通の後半。comments はスコープ解決済みの候補一覧。
-- 0 件 (全 outdated / 空) はコピーせず info_msg を出して空データを返す。
local function emit(session, comments, opts, header, info_msg)
  local included, excluded = core_prompt.filter_active(comments)
  if #included == 0 then
    notify_info(info_msg(#comments))
    return result.ok { text = '', count = 0 }
  end
  if excluded > 0 then
    notify_info(('%d 件を除外しました (outdated)'):format(excluded))
  end
  local ctx = ctx_for(session)
  local text = header and core_prompt.build(comments, ctx) or core_prompt.body(comments, ctx)
  if opts == nil or opts.copy ~= false then
    copy_text(text)
  end
  return result.ok { text = text, count = #included }
end

local function not_active()
  notify_warn 'レビュー進行中セッションがありません'
  return result.err(
    'review.nvim: レビュー進行中セッションがありません',
    result.codes.E_NOT_ACTIVE
  )
end

-- 空候補時のメッセージ使い分け (ai-prompt.md エッジケース): 本文 0 件 =
-- 「コメントがありません」、全件 outdated (候補あり active 0) = 「有効なコメントがありません」。
local function empty_msg(total)
  return total == 0 and 'コメントがありません'
    or '有効なコメントがありません'
end

--- :Review prompt (全コメント)。opts = { copy? }。
function M.all(opts)
  local session = session_handler.active()
  if session == nil then
    return not_active()
  end
  return emit(session, session.comments, opts, true, empty_msg)
end

--- :Review prompt [file] (そのファイルのコメントのみ)。
function M.for_file(path, opts)
  local session = session_handler.active()
  if session == nil then
    return not_active()
  end
  if session.files == nil or session.files[path] == nil then
    notify_info 'そのファイルはレビュー対象の diff にありません'
    return result.ok { text = '', count = 0 }
  end
  local scoped = {}
  for _, c in ipairs(session.comments) do
    if c.file == path then
      scoped[#scoped + 1] = c
    end
  end
  return emit(session, scoped, opts, true, empty_msg)
end

--- y キー: カーソル行 range のコメントのみ (見出しなし)。呼び出し側 (handlers/comments)
--- が「その行のコメントはありません」までは WARN 済み。
function M.for_line(session, found, opts)
  return emit(session, found, opts, false, function()
    return 'outdated のためプロンプトに含めませんでした'
  end)
end

return M
