-- E2E phase 3 (head 省略経路 / 新契約)。`:Review start main` (1 引数) が
-- `rev-parse --abbrev-ref HEAD` (実 git) で現在のブランチ名を自動解決・保存し、
-- 入力 UI を出さずに開始することを pin する。hotfix へ checkout してから実行し、
-- 保存 head が literal ブランチ名 (hotfix) であることをセッション JSON で確認する
-- (head == 現在の HEAD なので作業ツリー基準の単引数 `git diff main` で開通)。
-- head 解決フローの switch 提案 / scratch 縮退の分岐は unit (session_spec の
-- 応答キュー) で pin 済み。ここでは「自動採用が実 git で動く」接線のみを検証する。

local windows = require 'review.ui.windows'

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    fail('timeout: ' .. why)
  end
end

local function git(args)
  local out = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait(10000)
  if out.code ~= 0 then
    fail('git ' .. table.concat(args, ' ') .. ' 失敗: ' .. (out.stderr or ''))
  end
end

-- 比較は symlink 解決後の実パスで行う (macOS /var -> /private/var)。
-- gsub の多値戻りを実関数に直接渡さない (余分な second result が引数になる)。
local function realpath(p)
  local s = (p or ''):gsub('[\r\n]+$', '')
  return vim.uv.fs_realpath(s) or s
end

local function top_level()
  return realpath(
    vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { text = true }):wait(10000).stdout
  )
end

local function run()
  git { 'checkout', '-q', 'hotfix' }

  vim.cmd 'Review start main'

  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--hotfix' == 1
  end, 'head 自動採用後の session 開始 (sidebar main--hotfix)')
  -- 初期開き = 一覧先頭ファイルの open_file: head 窓は実ファイル (hotfix の a.lua)
  wait_for(function()
    return windows.state() ~= nil and windows.win 'head' ~= nil
  end, 'hotfix レビュー 3 窓')
  local head = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(windows.win 'head'))
  if head ~= realpath(vim.fs.joinpath(top_level(), 'a.lua')) then
    fail('head 自動採用後の head 窓が実ファイルでない: ' .. head)
  end

  -- 保存された head は自動解決されたブランチ名 (DESIGN「データスキーマ」head 保存表現)
  local session_handler = require 'review.handlers.session'
  local sess = session_handler.active()
  if sess == nil or sess.head ~= 'hotfix' then
    fail('head 自動採用が保存されていない: ' .. tostring(sess and sess.head))
  end
  if sess.base ~= 'main' or sess.mode ~= 'branch' then
    fail 'セッション refs が不一致'
  end
  print 'E2E-S3 head=hotfix'

  -- 後続に open セッションを残さない (コメント 0 件 = 無確認で閉じる)
  vim.cmd 'Review close'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--hotfix' == 0
  end, 'close 後 sidebar 消滅')

  -- fixture の 체크아웃位置を phase 間の前提 (feature) に戻す
  git { 'checkout', '-q', 'feature' }
  vim.cmd 'qa'
end

vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
