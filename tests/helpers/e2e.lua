-- e2e シナリオ共有: 失敗の正規化・条件待ち・パス正規化・git 実行。
-- 失敗は E2E-FAIL を stdout へ出して cquit する (-c 実行中に error を素出しすると
-- headless nvim が入力待ちになりハングするため)。
local M = {}

function M.fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

function M.wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    M.fail('timeout: ' .. why)
  end
end

function M.expect(cond, why)
  if not cond then
    M.fail(why)
  end
end

--- 実パス正規化 (macOS /var -> /private/var)。git 出力由来の末尾改行は落とす。
function M.realpath(p)
  local s = (p or ''):gsub('[\r\n]+$', '')
  return vim.uv.fs_realpath(s) or s
end

--- cwd で git を実行し、末尾改行を落とした stdout を返す。失敗は fail。
function M.git(args)
  local out = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait(10000)
  if out.code ~= 0 then
    M.fail('git ' .. table.concat(args, ' ') .. ' 失敗: ' .. (out.stderr or ''))
  end
  return (out.stdout or ''):gsub('[\r\n]+$', '')
end

return M
