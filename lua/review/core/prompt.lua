-- AI プロンプト組み立ての純粋関数 (docs/design/features/ai-prompt.md「入出力と
-- 振る舞い」)。コメント -> 見出し行 (@path + 行アンカー) + 本文行。パス規則・
-- outdated 既定除外・見出し定型文の決定はすべてこの 1 箇所に置く (UI 層はコピー
-- のみ担う)。コメント順の契約は id 数値昇順 = 作成順 (DoD / テスト方針)。
local M = {}

--- outdated を除外した active 一覧を id 数値昇順で返す。
--- 戻り値 (active, excluded_count)。
function M.filter_active(comments)
  local active = {}
  local excluded = 0
  for _, c in ipairs(comments) do
    if c.state == 'outdated' then
      excluded = excluded + 1
    else
      active[#active + 1] = c
    end
  end
  table.sort(active, function(a, b)
    return tonumber(a.id:match '^c(%d+)$') < tonumber(b.id:match '^c(%d+)$')
  end)
  return active, excluded
end

--- 見出し行 (all 出力のみ)。ctx = { mode, base, head, pr?, worktree_path? }。
--- 定型文は ai-prompt.md の正本 (branch / PR の 2 書式)。
function M.header(ctx)
  if ctx.mode == 'pr' then
    return ('Review PR #%d (%s) — %s..%s. Please address the comments below.'):format(
      ctx.pr.number,
      ctx.pr.url,
      ctx.base,
      ctx.head
    )
  end
  return ('Review the changes in %s..%s. Please address the comments below.'):format(
    ctx.base,
    ctx.head
  )
end

--- 1 コメントの見出し行のトークン `@<path>#L<行>`。worktree あり ctx では
--- worktree 基準の絶対 path、なしはリポジトリ相対 path (ai-prompt.md「パスの規則」)。
function M.ref(comment, ctx)
  local path = comment.file
  if ctx.worktree_path ~= nil then
    path = vim.fs.joinpath(ctx.worktree_path, comment.file)
  end
  local end_line = comment.end_line or comment.line
  local anchor = ('#L%d'):format(comment.line)
  if end_line ~= comment.line then
    anchor = anchor .. ('-L%d'):format(end_line)
  end
  return '@' .. path .. anchor
end

--- 本文のみ (見出しなし。y キー経路)。comments は呼び出し側の顺序のまま、
--- ブロックを空行で連結する。outdated は除外し、複数行 body は続き行として置く。
function M.body(comments, ctx)
  local blocks = {}
  for _, c in ipairs(M.filter_active(comments)) do
    blocks[#blocks + 1] = M.ref(c, ctx) .. '\n' .. c.body
  end
  return table.concat(blocks, '\n\n')
end

--- all 出力 (見出し + 本文)。
function M.build(comments, ctx)
  return M.header(ctx) .. '\n\n' .. M.body(comments, ctx)
end

return M
