-- spec 共有: handlers 系 spec (セッションを実開始する土俵) の環境部品。
-- tmpdir / 実ファイル付き repo の用意、store・session の DI 固定、vim.notify /
-- vim.ui.input の spy、3 窓 UI と専有 tab の後始末を手続きとして提供する。
-- フックの登録と呼び出し順は各 spec の use_env() が持つ (spec ごとの差分を
-- その場で読めるようにするため、ここではまとめて登録しない)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local nvim_env = require 'helpers.nvim_env'
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'

local M = {}

-- 注入時刻 (store / session_handler の now)。
M.NOW = 4321

local function now()
  return M.NOW
end

--- state.dir = 新しい tmpdir。files (relpath -> 本文) を渡すと state.dir/repo に
--- 実ファイルとして書き出し、state.repo = その実パス (fs_realpath 正規化) にする
--- (head 実ファイル窓の :edit 相当はディスク実在が前提)。
function M.make_dirs(state, files)
  state.dir = vim.fn.tempname()
  vim.fn.mkdir(state.dir, 'p')
  if files == nil then
    return
  end
  local raw = vim.fs.joinpath(state.dir, 'repo')
  vim.fn.mkdir(raw, 'p')
  for name, body in pairs(files) do
    local path = vim.fs.joinpath(raw, name)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local f = assert(io.open(path, 'w'))
    f:write(body)
    f:close()
  end
  state.repo = vim.uv.fs_realpath(raw) or raw
end

--- data dir を state.dir に注入し、store / session_handler の時刻と store 通知を固定、
--- session_handler の active 状態を初期化する。
function M.inject_store(state)
  paths._set_data_dir(state.dir)
  store._set_now(now)
  store._set_notify(function() end)
  session_handler._set_now(now)
  session_handler._reset()
end

--- vim.notify を {msg, level} の state.notifications 記録に差し替える。
--- filter_worktree = true のとき、worktree 作成中の過渡 notify は完了時に
--- nvim_echo クリアで消える実態をモデル化し、記録せず
--- state.worktree_notify_shown = true だけ立てる。
function M.capture_notify(state, filter_worktree)
  vim.notify = function(msg, level)
    if
      filter_worktree
      and type(msg) == 'string'
      and msg:find('creating the review worktree', 1, true)
    then
      state.worktree_notify_shown = true
      return
    end
    table.insert(state.notifications, { msg = msg, level = level })
  end
end

--- vim.ui.input を「opts を state.inputs に記録し state.input_answer で答える」spy に。
function M.answer_input(state)
  vim.ui.input = function(opts, cb)
    table.insert(state.inputs, opts)
    cb(state.input_answer)
  end
end

--- 3 窓 UI の窓状態を閉じて初期化する。
function M.reset_windows()
  if ui_windows.state() ~= nil then
    ui_windows.close()
  end
  ui_windows.reset()
end

--- active セッションを閉じる。close はコメントあり確認として vim.ui.input を引く
--- (headless の既定 provider は無限待ちになるため 'y' 応答に差し替えてから閉じる)。
function M.close_session()
  vim.ui.input = function(_, cb)
    cb 'y'
  end
  session_handler.close()
  vim.ui.input = nvim_env.REAL_INPUT
end

--- 差し替えた vim 組み込みと DI を全て戻し、config を初期化して state.dir を消す。
function M.release(state)
  vim.notify = nvim_env.REAL_NOTIFY
  vim.ui.input = nvim_env.REAL_INPUT
  vim.ui.select = nvim_env.REAL_SELECT
  paths._set_data_dir(nil)
  store._set_now(nil)
  store._set_notify(nil)
  session_handler._set_now(nil)
  session_handler._reset()
  config.reset()
  cli._set_system(nil)
  cli._set_executable(nil)
  vim.fn.delete(state.dir, 'rf')
end

--- レビュー専有 tab (無ければ nil)。
function M.review_tab()
  local st = ui_windows.state()
  return st and st.tab or nil
end

local function role_buf_name(role)
  local w = ui_windows.win(role)
  return w ~= nil and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) or nil
end

--- head / base 窓が表示しているバッファ名 (窓が無ければ nil)。
function M.head_buf_name()
  return role_buf_name 'head'
end

function M.base_buf_name()
  return role_buf_name 'base'
end

return M
