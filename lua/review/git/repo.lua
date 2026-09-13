-- `git switch <ref>` の実行アダプタ (diff-review.md「開始」head 解決フロー)。
-- switch はユーザーのチェックアウトを動かすため、実行は [y/N] 確認を通過した
-- ときだけ handler が呼ぶ (INV-3)。ここは実行と結果型変換のみを行い、可否の
-- 判断 (ローカルブランチ・clean 判定) と失敗後の縮退は handler の責務。
-- 失敗は E_GIT + stderr 主行を error に返す (git/cli 経由・外界 DI)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

--- cb(result)。opts = { ref, cwd }。リポ top (cwd) のチェックアウトを
--- ref へ切り替える。成功は data = { stdout, code } をそのまま返す。
function M.switch(opts, cb)
  local cfg = config.get()
  cli.run(
    cfg.git_bin,
    { 'switch', opts.ref },
    { cwd = opts.cwd, err_code = result.codes.E_GIT },
    cb
  )
end

return M
