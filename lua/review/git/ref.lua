-- branch / tag の列挙と rev-parse の git 実行アダプタ。
-- 用途は :Review start の head 補完 (diff-review.md「開始」手順 1: branches → tags 順)
-- と ref 検証。一覧には for-each-ref を使う (refs/heads 直下 + 下位ブランチを
-- refname 昇順で返す、git 旧来からサポートの安定 API)。
-- 実行・結果型変換は git/cli 経由。失敗 (repo 外・ref 解決不能) は E_REF。
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

local function run(args, opts, cb)
  local cfg = config.get()
  cli.run(cfg.git_bin, args, { cwd = opts.cwd, err_code = result.codes.E_REF }, cb)
end

-- stdout を行の配列へ。git は 1 リスト 1 行で出すので空行は捨てる。
local function split_lines(text)
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if line ~= '' then
      table.insert(out, line)
    end
  end
  return out
end

--- cb(result) result.data = branch 名の配列。
function M.branches(opts, cb)
  run({ 'for-each-ref', '--format=%(refname:short)', 'refs/heads/' }, opts, function(res)
    if not res.ok then
      cb(res)
      return
    end
    cb(result.ok(split_lines(res.data.stdout)))
  end)
end

--- cb(result) result.data = tag 名の配列。
function M.tags(opts, cb)
  run({ 'for-each-ref', '--format=%(refname:short)', 'refs/tags/' }, opts, function(res)
    if not res.ok then
      cb(res)
      return
    end
    cb(result.ok(split_lines(res.data.stdout)))
  end)
end

--- cb(result) result.data = ref のコミット sha (末尾改行除去済み)。解決不能は E_REF。
function M.rev_parse(opts, cb)
  run({ 'rev-parse', '--verify', opts.ref }, opts, function(res)
    if not res.ok then
      cb(res)
      return
    end
    cb(result.ok((res.data.stdout:gsub('[\r\n]+$', ''))))
  end)
end

return M
