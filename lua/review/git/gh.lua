-- gh CLI による PR 解決アダプタ (pr-worktree.md「PR 解決」手順 1)。
-- config.gh_bin 注入 (DESIGN.md「gh / git 実行」)。実行は git/cli と同じ境界で、
-- 不在は E_GH。失敗の使い分け: gh の stderr に未ログイン誘導文 (`gh auth login`)
-- があれば E_GH (通知文言を固定)、それ以外の失敗 (PR 非存在等) は E_PR。
-- 手続きは例外を投げず結果型で返す (DESIGN.md 横断規約)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

local JSON_FIELDS = 'number,title,baseRefName,headRefName,headRepositoryOwner,url,state'

--- opts = { target = PR 番号 or URL, cwd? }。
--- cb(result) result.data = gh pr view の JSON (number, title, baseRefName,
--- headRefName, headRepositoryOwner, url, state)。
function M.pr_view(opts, cb)
  local cfg = config.get()
  cli.run(
    cfg.gh_bin,
    { 'pr', 'view', opts.target, '--json', JSON_FIELDS },
    { cwd = opts.cwd, err_code = result.codes.E_GH },
    function(res)
      if not res.ok then
        -- 不在・起動失敗 (data なし) は gh の実行に到達していない → E_GH のまま
        if res.data == nil then
          cb(res)
          return
        end
        local err = res.error or ''
        if err:lower():find('gh auth login', 1, true) ~= nil then
          -- 理由文字列のみ返す (通知プレフィックスは caller 側 — 横断規約の通知形式)
          res.error = 'gh 未ログインです。`gh auth login` を実行してください'
          res.code = result.codes.E_GH
          cb(res)
          return
        end
        -- gh は走ったが PR を解決できない (非存在・repo 不一致等) = E_PR。
        -- stderr 末尾 1 行 (cli 整形済み) を理由としてそのまま返す。
        res.code = result.codes.E_PR
        cb(res)
        return
      end
      local ok_decode, meta = pcall(vim.json.decode, res.data.stdout)
      if not ok_decode or type(meta) ~= 'table' then
        cb(result.err('gh pr view の出力を解析できませんでした', result.codes.E_GH))
        return
      end
      cb(result.ok(meta))
    end
  )
end

return M
