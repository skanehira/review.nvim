-- E2E delete 掃除 (DoD シナリオ 5 後半)。closed + created_by_us dir 残骸 + 自前 ref
-- のセッションを :Review delete で dir + ref + JSON まで一掃することを assert。
local answers = { 'y' }
local idx = 0
vim.ui.input = function(opts, cb)
  idx = idx + 1
  cb(answers[idx] or 'y')
end

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local wt_root = assert(os.getenv 'REVIEW_E2E_WT', 'REVIEW_E2E_WT 未設定')
local json = assert(os.getenv 'REVIEW_E2E_JSON', 'REVIEW_E2E_JSON 未設定')
local repo = assert(os.getenv 'REVIEW_E2E_REPO', 'REVIEW_E2E_REPO 未設定')

local function ref_gone()
  local ph =
    io.popen(('git -C "%s" rev-parse --verify -q review-nvim/pr-7 2>/dev/null'):format(repo))
  local out = ph:read 'a'
  ph:close()
  return out == nil or out == ''
end

vim.defer_fn(function()
  local ok, err = pcall(function()
    vim.cmd 'Review delete pr-7'
    if
      not vim.wait(10000, function()
        return vim.uv.fs_stat(wt_root) == nil and vim.uv.fs_stat(json) == nil and ref_gone()
      end, 50)
    then
      fail 'delete 掃除 (dir/ref/JSON) timeout'
    end
    print 'E2E-PR6 swept=1'
    vim.cmd 'qa'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
