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

--- :Review start の cmdline 補完専用:**同期**で branches -> tags 順の 1 リスト
--- を返す (customlist はコールバック補完ができないため。DESIGN.md「既知の制約」
--- の補完 wait 例外)。1 系統でも成功すればその部分集合を ok で返し、両系統
--- 失敗のみ err (timeout は run_sync 上限で打ち切り)。
function M.refs_sync(opts)
  opts = opts or {}
  local cfg = config.get()
  local out = {}
  local fails = 0
  local last_err
  for _, namespace in ipairs { 'refs/heads/', 'refs/tags/' } do
    local res = cli.run_sync(cfg.git_bin, {
      'for-each-ref',
      '--format=%(refname:short)',
      namespace,
    }, {
      cwd = opts.cwd,
      timeout_ms = opts.timeout_ms,
      err_code = result.codes.E_REF,
    })
    if res.ok then
      for _, name in ipairs(split_lines(res.data.stdout)) do
        out[#out + 1] = name
      end
    else
      fails = fails + 1
      last_err = res.error
    end
  end
  if fails == 2 then
    return result.err(last_err, result.codes.E_REF)
  end
  return result.ok(out)
end

--- cwd からの repo top-level 絶対パスを解決する (起動時 scan / セッション repo)。
--- cb(result) result.data = repo top。repo 外は E_REF。
function M.top_level(opts, cb)
  run({ 'rev-parse', '--show-toplevel' }, opts, function(res)
    if not res.ok then
      cb(res)
      return
    end
    cb(result.ok((res.data.stdout:gsub('[\r\n]+$', ''))))
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

-- PR 用の自前一時 ref 名。fork PR の head は通常の branch ref として fetch
-- されないため refs/pull/<n>/head から採る (DESIGN.md「既知の制約」fork PR 行)。
-- 名前に PR 番号を含め衝突を防ぎ、決定的なので次回 fetch で上更新できる。
function M.pr_ref(number)
  return ('review-nvim/pr-%s'):format(tostring(number))
end

--- cb(result) result.data = 作った ref 名。
--- `git fetch <remote> refs/pull/<n>/head:review-nvim/pr-<n>`
--- (pr-worktree.md「PR 解決」手順 2。remote 選択は handler、失敗は E_REF)。
function M.fetch_pull(opts, cb)
  local ref_name = M.pr_ref(opts.number)
  run(
    { 'fetch', opts.remote, ('refs/pull/%s/head:%s'):format(tostring(opts.number), ref_name) },
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      cb(result.ok(ref_name))
    end
  )
end

-- fetch の右辺が短縮名 `review-nvim/pr-<n>` のとき git が実保存するフルネーム
-- (refs/heads/ 底下。`git update-ref -d` は短縮名を "bad name" で拒否するため
-- 掃除はこの形が要る — 2.x 実測、DESIGN.md「既知の制約」)。
function M.pr_ref_storage(number)
  return 'refs/heads/' .. M.pr_ref(number)
end

--- cb(result)。`git update-ref -d <ref>` (:Review delete の自前 ref 掃除)。
--- ref には保存フルネーム (pr_ref_storage) を渡すこと。
function M.delete_ref(opts, cb)
  run({ 'update-ref', '-d', opts.ref }, opts, cb)
end

--- cb(result) result.data = remote 名の配列 (fork fetch の remote 選択入力。
--- 同一 repo に headRefName の branch が無いときの fetch 先候補)。
function M.remotes(opts, cb)
  run({ 'remote' }, opts, function(res)
    if not res.ok then
      cb(res)
      return
    end
    cb(result.ok(split_lines(res.data.stdout)))
  end)
end

return M
