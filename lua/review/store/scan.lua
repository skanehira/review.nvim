-- 起動時スキャン: 当該 repo の status=open セッション検索
-- (docs/design/features/persistence-restore.md「入出力と振る舞い」起動時、
-- 「実装の配置」: 再開 notify と worktree 残骸掃除の兼用)。
-- 破損ファイルの退避は reader (store.session) 側が担うので、ここでは
-- status による絞り込みのみを行う。repo top の解決 (cwd → git) は呼び出し側。

local result = require 'review.core.result'
local session = require 'review.store.session'

local M = {}

-- status=open のセッション配列 (返り順は未規定。list と違い closed は除外)。
function M.open_sessions(repo)
  local open = {}
  for _, sess in ipairs(session.list(repo).data) do
    if sess.status == 'open' then
      open[#open + 1] = sess
    end
  end
  return result.ok(open)
end

return M
