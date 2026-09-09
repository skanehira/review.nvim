-- git worktree add / remove / prune / status / list の実行アダプタ
-- (pr-worktree.md「実装の配置」adapters 行、DESIGN.md「既知の制約」worktree 各行)。
-- add は `--detach` 固定 (branch checkout と競合しない。一時 ref 決定の行)。
-- 未コミット変更があると remove は失敗する (--force 確認の根拠になる行) ため、
-- status / remove の成否はそのまま結果型で返し、確認判断は handler が行う。
-- 失敗コードは E_WORKTREE。実行・結果型変換は git/cli 経由 (外界 DI)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

local function run(args, cwd, cb)
  local cfg = config.get()
  cli.run(cfg.git_bin, args, { cwd = cwd, err_code = result.codes.E_WORKTREE }, cb)
end

-- stdout を行の配列へ (空行は捨てる。porcelain 形式は 1 項目 1 行)。
local function split_lines(text)
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if line ~= '' then
      out[#out + 1] = line
    end
  end
  return out
end

--- cb(result) data = { path, ref }。`git worktree add --detach <path> <ref>`。
function M.add(opts, cb)
  run({ 'worktree', 'add', '--detach', opts.path, opts.ref }, opts.repo, function(res)
    cb(res.ok and result.ok { path = opts.path, ref = opts.ref } or res)
  end)
end

--- cb(result)。`git worktree remove <path>` (force 指定なら `remove --force`)。
function M.remove(opts, cb)
  local args = { 'worktree', 'remove' }
  if opts.force then
    args[#args + 1] = '--force'
  end
  args[#args + 1] = opts.path
  run(args, opts.repo, cb)
end

--- cb(result)。`git worktree prune` (残骸登録の掃除。add 衝突時の再試行用)。
function M.prune(opts, cb)
  run({ 'worktree', 'prune' }, opts.repo, cb)
end

--- cb(result) data = { dirty = bool, porcelain = string[] }。
--- `git -C <path> status --porcelain`。**path 消滅等は err で返す** —
--- 検知不能を clean と混同すると、close が黙って --force なし掃除に進み得る。
function M.status(opts, cb)
  run({ '-C', opts.path, 'status', '--porcelain' }, nil, function(res)
    if not res.ok then
      cb(res)
      return
    end
    cb(result.ok {
      dirty = #split_lines(res.data.stdout) > 0,
      porcelain = split_lines(res.data.stdout),
    })
  end)
end

-- git の管理外にある自前の worktree **dir そのもの**の再帰削除。
-- 呼び出し側は created_by_us=true の記録があるものだけに限る (INV-3)。
-- vim.fs.delete は Neovim に存在せず (0.13 nightly 実測)、vim.fs.rm は runtime
-- 下限 0.10 で保証がないため vim.uv のプリミティブで自前実装する。
function M.remove_dir(path)
  local stat = vim.uv.fs_stat(path)
  if stat == nil then
    return true -- 目標状態 (不存在) そのもの
  end
  if stat.type ~= 'directory' then
    return os.remove(path) ~= nil
  end
  local scan = vim.uv.fs_scandir(path)
  if scan == nil then
    return false
  end
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if name == nil then
      break
    end
    if not M.remove_dir(vim.fs.joinpath(path, name)) then
      return false
    end
  end
  -- vim.uv.fs_rmdir は成功 true / 失敗 (nil, err) を返す (0.13 nightly 実測)
  return vim.uv.fs_rmdir(path) == true
end

--- cb(result) data = worktree の絶対パス配列。`git worktree list --porcelain`。
--- 起動 scan / 作成判断の「登録済みか」の判定に使う。
function M.list(opts, cb)
  run({ 'worktree', 'list', '--porcelain' }, opts.repo, function(res)
    if not res.ok then
      cb(res)
      return
    end
    local paths = {}
    for _, line in ipairs(vim.split(res.data.stdout, '\n', { plain = true })) do
      local path = line:match '^worktree (.*)$'
      if path ~= nil then
        paths[#paths + 1] = path
      end
    end
    cb(result.ok(paths))
  end)
end

return M
