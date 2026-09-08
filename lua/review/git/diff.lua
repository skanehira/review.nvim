-- `git diff <base> <head>` によるブランチレビュー差分の取得アダプタ
-- (diff-review.md「開始」手順 2)。config の diff_context 指定時は -U<n> を付ける。
-- 生出力からの new 側行番号への変換は core/diff のみが行うため
-- (DESIGN.md「既知の制約」)、ここは生出力を渡して parse 結果を添えるだけ。
-- ref 解決不能は E_REF として返す (diff-review.md「ref 解決不能は E_REF を通知」)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local core_diff = require 'review.core.diff'
local result = require 'review.core.result'

local M = {}

--- 非同期実行し、cb に結果型 { ok, data = { text, files } | ..., error, code } を返す。
--- opts = { base, head, cwd? }。cb は cli.run によりスローイベントで呼ばれる。
function M.fetch(opts, cb)
  local cfg = config.get()
  local args = { 'diff' }
  if cfg.diff_context ~= nil then
    table.insert(args, '-U' .. cfg.diff_context)
  end
  table.insert(args, opts.base)
  table.insert(args, opts.head)

  cli.run(cfg.git_bin, args, { cwd = opts.cwd, err_code = result.codes.E_REF }, function(res)
    if not res.ok then
      cb(res)
      return
    end
    cb(result.ok {
      text = res.data.stdout,
      files = core_diff.parse(res.data.stdout),
    })
  end)
end

return M
