-- E2E phase 4 (cmdline ref 補完)。実 fixture repo を cwd に、`:Review start` の
-- base/head 補完を本物の git for-each-ref 同期経路で検証する (注入なし)。
-- popup 自体の描画は headless で不安定なため (既知の制約: :normal のみ安定)、
-- customlist の呼び出し側 = review.complete の戻り値をキー入力相当の
-- (引数, cmdline) 組で検証する。UI 実表示は手動確認。
local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function run()
  local review = require 'review'

  local all = review.complete('', 'Review start ', 0)
  local joined = table.concat(all, ',')
  for _, want in ipairs { 'feature', 'hotfix', 'main' } do
    if (' ' .. table.concat(all, ' ') .. ' '):find(' ' .. want .. ' ', 1, true) == nil then
      fail('実 git 補完候補に ' .. want .. ' が無い: ' .. joined)
    end
  end
  -- branches 内は refname 昇順、この fixture に tags は無い (tags 系統は空で ok)
  if all[1] ~= 'feature' or all[2] ~= 'hotfix' or all[3] ~= 'main' then
    fail('branches 順序が refname 昇順でない: ' .. joined)
  end

  local one = review.complete('fe', 'Review start fe', 0)
  if #one ~= 1 or one[1] ~= 'feature' then
    fail('lead fe の prefix 一致が違う: ' .. table.concat(one, ','))
  end

  -- head 位置 (base を打った後の 3 語目以降) も同じ候補源
  local at_head = review.complete('ho', 'Review start main ho', 0)
  if #at_head ~= 1 or at_head[1] ~= 'hotfix' then
    fail('head 位置の補完が違う: ' .. table.concat(at_head, ','))
  end

  local none = review.complete('zzz', 'Review start zzz', 0)
  if #none ~= 0 then
    fail('不一致候補が空でない: ' .. table.concat(none, ','))
  end

  -- サブコマンド位置では git を引かない (start 候補に混ざらない)
  local subs = review.complete('s', 'Review s', 0)
  if #subs ~= 1 or subs[1] ~= 'start' then
    fail('サブコマンド位置の候補が壊れた: ' .. table.concat(subs, ','))
  end

  print('E2E-C1 completion=' .. joined)

  -- :Review delete <id> 補完: 実 git rev-parse + 実 store (tmp data dir に隔離) を
  -- 同期経路で引く。pr の gh 補完は e2e fixture に gh 必須にしない (unit stub)。
  local paths = require 'review.store.paths'
  local store = require 'review.store.session'
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, 'p')
  paths._set_data_dir(tmp)
  store.save {
    repo = vim.fn.trim(vim.fn.system { 'git', 'rev-parse', '--show-toplevel' }),
    id = 'main--e2e-del',
    base = 'main',
    head = 'e2e-del',
    mode = 'branch',
    state = 'closed',
    comments = {},
  }
  local ids = review.complete('main--', ':Review delete main--', 0)
  if #ids ~= 1 or ids[1] ~= 'main--e2e-del' then
    paths._set_data_dir(nil)
    fail('delete id 補完が違う: ' .. table.concat(ids, ','))
  end
  paths._set_data_dir(nil)
  print('E2E-C2 delete_ids=' .. table.concat(ids, ','))

  vim.cmd 'qa'
end

vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)
