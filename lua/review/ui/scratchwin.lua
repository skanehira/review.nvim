-- ui/scratchwin: 窓 diff の scratch 側バッファ (docs/design/features/diff-review.md
-- 「head / base 窓の中身」)。kind に応じた `review://<kind>/<session>/<path>` の
-- 名前と bufhidden=hide / modifiable=false / filetype detect だけを持つ。
-- git 実行は持たない (内容充填は呼び出し側 = handlers/session。DESIGN.md 層構成の
-- 「ui は git を直接叩かない」に従い、scratch 側の真実は常に関数引き渡し側にある)。
-- 削除告知は :edit ではなくこの scratch にする (DESIGN「既知の制約」削除ファイル:
-- 実パスを :edit すると `:w` で空ファイルが復活する)。
local M = {}

M.NOTIFY = {
  deleted = { '■ deleted (head に存在しません — base 側は左窓)' },
  binary = { 'Binary files differ' },
}

local KINDS = { base = true, head = true, null = true, deleted = true, binary = true }

--- opts = { kind, session_id, path } -> bufnr (同名バッファは再利用)。
--- 内容は触らない (新規は 0 行、再利用時は既存内容が残る = 呼び出し側が
--- set_content で全面置換する)。
function M.buffer(opts)
  if KINDS[opts.kind] ~= true then
    error('scratchwin: unknown kind ' .. tostring(opts.kind), 2)
  end
  local name = ('review://%s/%s/%s'):format(opts.kind, opts.session_id, opts.path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  -- 同名再利用で前回内容を残さないため 0 内容へ正規化してから返す
  -- (null scratch = 中身なしが契約。vim の空バッファは 1 個の空行で表現される)。
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modifiable = false
  vim.b[buf].review_meta = {
    kind = 'scratch',
    scratch = opts.kind,
    session_id = opts.session_id,
    path = opts.path,
  }
  return buf
end

--- read-only のまま中身を全面置換する (差分再取得で残り行を残さない)。
function M.set_content(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.bo[buf].modifiable = false
end

--- 実ファイル名 (repo 相対 path) から filetype を当てる。判定不能なら空のまま
--- (FileType autocmd 分岐は使わない — buffer 側の性質として載せるだけ)。
function M.detect_filetype(buf, path)
  local detected = vim.filetype.match { filename = path }
  if detected ~= nil then
    vim.bo[buf].filetype = detected
  end
end

return M
