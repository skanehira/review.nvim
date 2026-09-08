-- 手続きの共通返り値 (DESIGN.md「横断規約」結果型)。
-- 手続きは例外を投げず、常にこの形のテーブルを返す。
local M = {}

-- 結果テーブルに付ける識別子。異物テーブルと混同したまま下游へ渡さないための印。
M.class = 'review.Result'

M.codes = {
  E_GIT = 'E_GIT',
  E_GH = 'E_GH',
  E_REF = 'E_REF',
  E_PR = 'E_PR',
  E_WORKTREE = 'E_WORKTREE',
  E_STORE = 'E_STORE',
  E_CANCELLED = 'E_CANCELLED',
  E_NOT_ACTIVE = 'E_NOT_ACTIVE',
}

function M.ok(data)
  return { __class = M.class, ok = true, data = data }
end

function M.err(error, code)
  return { __class = M.class, ok = false, error = error, code = code }
end

return M
