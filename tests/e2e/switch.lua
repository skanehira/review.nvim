-- E2E head 解決フロー / switch 分支 (diff-review「開始」2、DESIGN 決定表「head が
-- 現在の HEAD と違うとき」)。fixture REPO2 (checkout=main、feature が 2 ファイル
-- 先行) で `:Review start main feature` (head 明示・HEAD!=feature・ブランチ clean)
-- -> [y/N] 提案 (語句は unit が正本、ここでは「実 vim.ui.input 経路で提案が来る」
-- ことと応答 y) -> y -> `git switch feature` が**実 git で実行され**、通常経路
-- (実ファイル head 窓・作業ツリー基準 diff) で開通することを pin する。
-- 縮退しなかったこと (読み取り専用 scratch の INFO がこの run の log に無い) は
-- shell 側 grep、switch の実行は shell 側 rev-parse でも二重に確認する。
-- 失敗は E2E-FAIL + cquit (契約は phase1 と同一)。

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

local function realpath(p)
  return vim.uv.fs_realpath(p) or p
end

local function git(args)
  local out = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait(10000)
  if out.code ~= 0 then
    fail('git ' .. table.concat(args, ' ') .. ' 失敗: ' .. (out.stderr or ''))
  end
  return (out.stdout or ''):gsub('[\r\n]+$', '')
end

local run = function()
  -- 単独実行でも決定的にする (switch.lua 側で feature に switch した残害の正規化)。
  git { 'checkout', '-q', 'main' }
  if git { 'rev-parse', '--abbrev-ref', 'HEAD' } ~= 'main' then
    fail '前提の checkout=main が作れない'
  end

  -- 提案の応答スタブ (phase2 の close 確認と同じ手法)。prompt はここで撮り、
  -- switch の実行後に実ファイル経路であることを assert 対象へ渡す。
  local offers = {}
  local session_handler = require 'review.handlers.session'
  session_handler._set_confirm(function(prompt, cb)
    offers[#offers + 1] = prompt
    cb(true)
  end)

  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, 'switch 承諾後の開始 (sidebar main--feature)')

  -- [y/N] 提案が 1 回だけ来ること (switch_offer の語句は正本の実装文言)。
  if #offers ~= 1 then
    fail('switch 提案の回数が ' .. #offers .. ' (期待 1): ' .. vim.inspect(offers))
  end
  local want_offer = 'review.nvim: head feature は現在のチェックアウトと別のコミットです。'
    .. 'git switch で feature に切り替えてレビューしますか? [y/N]: '
  if offers[1] ~= want_offer then
    fail('switch 提案の文言が不一致: ' .. tostring(offers[1]))
  end

  -- 承諾 -> 実 git で switch が走っていること (リポジトリの実状態が証拠)。
  if git { 'rev-parse', '--abbrev-ref', 'HEAD' } ~= 'feature' then
    fail(
      'git switch feature が実行されていない: HEAD='
        .. git { 'rev-parse', '--abbrev-ref', 'HEAD' }
    )
  end

  -- 通常経路 = 実ファイル head 窓 (編集可) + tcd==REPO2 + 作業ツリー表示名。
  local st = windows.state()
  if st == nil or #vim.api.nvim_tabpage_list_wins(st.tab) ~= 3 then
    fail 'switch 承諾後に専有 tab 3 窓が開かない'
  end
  local top = realpath(git { 'rev-parse', '--show-toplevel' })
  local head_win = windows.win 'head'
  local hb = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(head_win))
  if hb ~= realpath(vim.fs.joinpath(top, 'a.lua')) then
    fail('switch 後の head 窓が実ファイルでない: ' .. hb)
  end
  local hbuf = vim.api.nvim_win_get_buf(head_win)
  if not vim.bo[hbuf].modifiable or vim.bo[hbuf].readonly then
    fail 'switch 後の head 実ファイル窓が編集不可 (縮退している)'
  end
  local lines = vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)
  if lines[1] ~= 'ONE changed' then
    fail('switch 後の作業ツリー内容が feature 側でない: ' .. tostring(lines[1]))
  end
  local tabnr = nil
  for i, t in ipairs(vim.api.nvim_list_tabpages()) do
    if t == st.tab then
      tabnr = i
    end
  end
  if realpath(vim.fn.getcwd(-1, tabnr)) ~= top then
    fail('tcd が REPO2 でない: ' .. vim.fn.getcwd(-1, tabnr))
  end
  local sb = vim.api.nvim_buf_get_lines(vim.fn.bufnr 'review://sidebar/main--feature', 0, -1, false)
  if sb[2] ~= 'Showing changes for: main..作業ツリー' then
    fail(
      'switch 承諾後の panel ヘッダが通常経路表示名でない: ' .. tostring(sb[2])
    )
  end

  print('E2E-SW1 switch=real head=' .. hb)
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
