-- spec 共有: store 層 spec の隔離。tmpdir を data dir に注入し (本物の stdpath を
-- 汚さない)、時刻・rename・通知の境界を DI で固定する。
local paths = require 'review.store.paths'
local session = require 'review.store.session'

local M = {}

--- before_each / after_each を登録し、テスト本体が参照する state を返す。
--- state.dir = 注入した data dir / state.notices = store の通知 {msg, level}。
--- rename は既定 (nil) に戻す (テストが差し替えても次へ漏らさない)。
function M.isolate_store(now)
  local state = {}
  before_each(function()
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    state.notices = {}
    paths._set_data_dir(state.dir)
    session._set_now(function()
      return now
    end)
    session._set_rename(nil)
    session._set_notify(function(msg, level)
      table.insert(state.notices, { msg = msg, level = level })
    end)
  end)
  after_each(function()
    paths._set_data_dir(nil)
    session._set_now(nil)
    session._set_rename(nil)
    session._set_notify(nil)
    vim.fn.delete(state.dir, 'rf')
  end)
  return state
end

return M
