-- E2E head 解決フロー / 縮退再開始 (diff-review「開始と既存セッションの継承」+
-- 復元時も head 解決フローを毎回再評価する: DESIGN 決定表「起動時復元」)。
-- fixture REPO2 を main チェックアウトのまま使う。
-- STEP=1: 缩退で初回開始 (`:Review start main feature` + n 応答) -> 両窓 scratch、
--         セッションは open で保存される (プロセスは qa で終了)。
-- STEP=2: 同じ refs 組をもう一度開始 (同一データ dir)。HEAD!=feature のままなので
--         head 解決が**継承時も再評価**され、再び n 応答 -> 両窓 review://head|base
--         scratch + INFO (縮退状態の再取得引数形 <base> <head> で差分も縮退基準)。
--         「session JSON に載せない degraded を復元・開き直しで毎回再評価する」の
--         実 git 証跡 (persistence-restore「復元」/ session.lua の degrade 注記)。
-- INFO 語句のログ出現は shell 側 grep が陽性対照。失敗は E2E-FAIL + cquit。

local windows = require 'review.ui.windows'

local step = assert(os.getenv 'REVIEW_E2E_STEP', 'REVIEW_E2E_STEP 未設定')

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
  return (out.stdout or ''):gsub('[\r\n]+$', '')
end

local run = function()
  git { 'checkout', '-q', 'main' }
  if git { 'rev-parse', '--abbrev-ref', 'HEAD' } ~= 'main' then
    fail '前提の checkout=main が作れない'
  end

  -- STEP=2 は同一 refs 組の既存セッションがあるため «継承して開きますか? [y/N]»
  -- が先に来る (diff-review「開始と既存セッションの継承」)。承諾 -> y、その後の
  -- switch 提案 -> n。想定外の入力要求は即失敗させる (黙って詰まらない)。
  local answers = step == '2' and { { 'y', '継承' }, { 'n', 'switch' } } or { { 'n', 'switch' } }
  local switch_offers = 0
  vim.ui.input = function(opts, cb)
    local is_switch = (opts.prompt or ''):find('git switch', 1, true) ~= nil
    if is_switch then
      switch_offers = switch_offers + 1
    end
    local next_q = answers[1]
    if next_q == nil or (next_q[2] == 'switch') ~= is_switch then
      fail('想定外の入力要求: ' .. tostring(opts.prompt))
    end
    table.remove(answers, 1)
    cb(next_q[1])
  end

  -- 2 回目 (STEP=2) は起動 scan の継続通知が出てから (継承対象が store に在る)。
  if step == '2' then
    local log_path = os.getenv 'REVIEW_E2E_LOG'
    wait_for(function()
      local f = log_path ~= nil and io.open(log_path, 'r')
      if f == nil then
        return false
      end
      local text = f:read '*a' or ''
      f:close()
      return text:find('review.nvim: main--feature のレビューが続けられます', 1, true)
        ~= nil
    end, 'STEP=2 起動継続 notify')
  end

  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, '縮退開始 (sidebar main--feature)')
  if switch_offers ~= 1 then
    fail('STEP=' .. step .. ' の switch 提案回数が ' .. switch_offers .. ' (期待 1)')
  end
  if #answers ~= 0 then
    fail(
      'STEP='
        .. step
        .. ' で期待した入力要求が来なかった (残り '
        .. #answers
        .. ' 件)'
    )
  end

  local head_win, base_win = windows.win 'head', windows.win 'base'
  if head_win == nil or base_win == nil then
    fail('STEP=' .. step .. ' の縮退 3 窓が導出できない')
  end
  local head_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(head_win))
  local base_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(base_win))
  if head_name ~= 'review://head/main--feature/a.lua' then
    fail('STEP=' .. step .. ' の head 窓が review://head scratch でない: ' .. head_name)
  end
  if base_name ~= 'review://base/main--feature/a.lua' then
    fail('STEP=' .. step .. ' の base 窓が review://base scratch でない: ' .. base_name)
  end

  if step == '2' then
    -- 継承でセッションが二重化していないこと (1 組 1 セッション) + status=open。
    local jsons = vim.fn.glob(
      (vim.fn.stdpath 'data') .. '/review.nvim/sessions/*/main--feature.json',
      false,
      true
    )
    if #jsons ~= 1 then
      fail('再開始後のセッション JSON が ' .. #jsons .. ' 件: ' .. vim.inspect(jsons))
    end
    local sess = vim.json.decode(table.concat(vim.fn.readfile(jsons[1]), '\n'))
    if sess.status ~= 'open' or sess.head ~= 'feature' then
      fail('再開始後のセッション記録が不一致: ' .. vim.inspect(sess.status))
    end
    print 'E2E-DR2 restart=degraded session=open'
  else
    print 'E2E-DR1 degraded=once'
  end

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
