-- git / gh 共通の実行アダプタ (DESIGN.md「横断規約」の vim.system 境界)。
-- 外界 DI: vim.system / vim.fn.executable はモジュール内変数に間接参照し、
-- _set_system / _set_executable で注入できる (テストは stub、UI 層は本物)。
local result = require 'review.core.result'

local M = {}

local system = vim.system
local executable = vim.fn.executable

-- nil を渡すと本物へ戻す。
function M._set_system(fn)
  system = fn or vim.system
end

function M._set_executable(fn)
  executable = fn or vim.fn.executable
end

-- コールバックは fast event の可能性があるため、UI 触れる側へは常に
-- スローイベントで返す (DESIGN.md「横断規約」非同期)。
local function deliver(cb, res)
  if vim.in_fast_event() then
    vim.schedule(function()
      cb(res)
    end)
  else
    cb(res)
  end
end

-- stderr を末尾 1 行に整形する (ユーザー通知にそのまま使うため)。
-- 末尾の改行 / 空行は捨てる。空なら nil。
local function stderr_last_line(stderr)
  local s = (stderr or ''):gsub('[\r\n]+$', '')
  if s == '' then
    return nil
  end
  return (s:match '[^\r\n]*$')
end

--- bin を args で実行し、結果型を cb に非同期で返す。
--- opts は vim.system への転送用。`err_code` のみ特別扱いで、
--- 失敗時のエラーコードを決める (既定 E_GIT、gh 側は E_GH を渡す)。
--- cb は慢イベントで呼ばれる (ディスパッチ済み)。bin が実行不能なら
--- system を起動せず、同期的に err 結果を cb へ返す。
function M.run(bin, args, opts, cb)
  opts = opts or {}
  local err_code = opts.err_code or result.codes.E_GIT

  if executable(bin) ~= 1 then
    deliver(cb, result.err(bin .. ' が見つかりません', err_code))
    return
  end

  local sys_opts = {}
  for key, value in pairs(opts) do
    if key ~= 'err_code' then
      sys_opts[key] = value
    end
  end
  sys_opts.text = true

  local function on_exit(out)
    local code = out.code or 0
    local data = { stdout = out.stdout or '', code = code }
    if out.err ~= nil then
      -- 実行不能の race 検出は executable チェックで防ぐが、spawn 自体の
      -- 予想外失敗を result.ok 相当の形で下游へ渡さないための最終境界。
      deliver(cb, {
        __class = result.class,
        ok = false,
        data = data,
        error = bin .. ' の起動に失敗しました',
        code = err_code,
      })
    elseif code == 0 then
      deliver(cb, result.ok(data))
    else
      deliver(cb, {
        __class = result.class,
        ok = false,
        data = data,
        error = stderr_last_line(out.stderr)
          or (bin .. ' が終了コード ' .. code .. ' で失敗しました'),
        code = err_code,
      })
    end
  end

  -- Neovim の実装により vim.system は spawn 失敗を同期的に投げる
  -- (cwd 不正など)。横断規約「手続きは例外を投げず結果型を返す」を
  -- アダプタ境界で守るため pcall で吸収する (DESIGN.md 横断規約)。
  local spawned = pcall(system, vim.list_extend({ bin }, args or {}), sys_opts, on_exit)
  if not spawned then
    deliver(cb, result.err(bin .. ' の起動に失敗しました', err_code))
  end
end

--- run と同じ実行・結果型変換を同期的に行う。**cmdline 補完専用**
--- (customlist は同期関数なので cb を待てない。DESIGN.md「既知の制約」の
--- 補完 wait 例外行)。opts.timeout_ms (既定 250) を超えたらプロセスを kill して
--- err に変換し、待ち受けフリーズを防ぐ。
function M.run_sync(bin, args, opts)
  opts = opts or {}
  local err_code = opts.err_code or result.codes.E_GIT
  local timeout = opts.timeout_ms or 250

  if executable(bin) ~= 1 then
    return result.err(bin .. ' が見つかりません', err_code)
  end

  local sys_opts = {}
  for key, value in pairs(opts) do
    if key ~= 'err_code' and key ~= 'timeout_ms' then
      sys_opts[key] = value
    end
  end
  sys_opts.text = true

  local ok_spawn, handle = pcall(system, vim.list_extend({ bin }, args or {}), sys_opts)
  if not ok_spawn or handle == nil then
    return result.err(bin .. ' の起動に失敗しました', err_code)
  end

  local ok_wait, out = pcall(function()
    return handle:wait(timeout)
  end)
  if not ok_wait or out == nil then
    -- 待てないなら落とす (完了通知を待つと補完 UI が固まる)。kill 失敗は無視。
    pcall(function()
      handle:kill(9)
    end)
    return result.err(
      bin .. ' が同期実行の待ち時間内に完了しませんでした',
      err_code
    )
  end

  local code = out.code or 0
  local data = { stdout = out.stdout or '', code = code }
  if out.err ~= nil then
    return {
      __class = result.class,
      ok = false,
      data = data,
      error = bin .. ' の起動に失敗しました',
      code = err_code,
    }
  elseif code == 0 then
    return result.ok(data)
  end
  return {
    __class = result.class,
    ok = false,
    data = data,
    error = stderr_last_line(out.stderr)
      or (bin .. ' が終了コード ' .. code .. ' で失敗しました'),
    code = err_code,
  }
end

return M
