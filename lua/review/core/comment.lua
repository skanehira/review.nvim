-- コメントモデル (DESIGN.md「データスキーマ」Comment 定義)。
-- session の comments 配列に対する追加・編集・削除・カーソル行検索と、
-- id 採番 (c<n> / 既存 max+1)・range 正規化の純粋ロジック。
-- 採番も正規化もこの 1 箇所に集約する (INV-2 の range 条件は呼び出し側
-- = レビュー UI が差分側行番号から作る input を正規化して受け取る)。
-- 時刻 (created_at) は model で取らず attrs で受け取る (外界 DI)。
local M = {}

--- 既存 comments から次の id 'c<max+1>' を採番する (文字列順でなく数値比較)。
function M.new_id(comments)
  local max = 0
  for _, c in ipairs(comments) do
    local n = tonumber(c.id:match '^c(%d+)$')
    if n and n > max then
      max = n
    end
  end
  return 'c' .. (max + 1)
end

--- range を line <= end_line に正規化する。end_line 省略は単一行 (line と同値)。
--- visual-line の逆方向選択では range 末尾が先頭より小さい行になるため、
--- 入れ替えて保持する (diff-review.md「操作」の c に対する正規化)。
function M.normalize_range(line, end_line)
  if end_line == nil then
    return line, line
  end
  if end_line < line then
    return end_line, line
  end
  return line, end_line
end

--- attributes からコメントを作り comments 末尾へ追加して返す。
--- attrs: { file, line, end_line?, body, anchor?, created_at }。
--- id/state/end_line はここで付与・正規化するため attrs の同名キーは使わない。
--- anchor は DESIGN.md スキーマの { before, line, after } を呼び出し側の値のまま保持する。
function M.add(comments, attrs)
  local line, end_line = M.normalize_range(attrs.line, attrs.end_line)
  local created = {
    id = M.new_id(comments),
    file = attrs.file,
    line = line,
    end_line = end_line,
    body = attrs.body,
    anchor = attrs.anchor,
    state = 'active',
    created_at = attrs.created_at,
  }
  table.insert(comments, created)
  return created
end

--- id でコメントを探して body を更新し、更新後のコメントを返す。見つからなければ nil。
--- anchor は「追加時点」の行テキストなので編集でも据え置く (DESIGN.md スキーマ)。
function M.update(comments, id, body)
  for _, c in ipairs(comments) do
    if c.id == id then
      c.body = body
      return c
    end
  end
  return nil
end

--- id でコメントを探して comments から削除し、削除したコメントを返す。見つからなければ nil。
function M.remove(comments, id)
  for i, c in ipairs(comments) do
    if c.id == id then
      return table.remove(comments, i)
    end
  end
  return nil
end

--- ファイル内で new 側ファイル行 line を range [line..end_line] に含む
--- コメントを保持順で返す (diff キーマップ e / d の「カーソル行のコメント」)。
--- 単一キーの場合は find_at(comments, file, line)[1] で取る。
function M.find_at(comments, file, line)
  local found = {}
  for _, c in ipairs(comments) do
    if c.file == file and c.line <= line and line <= c.end_line then
      table.insert(found, c)
    end
  end
  return found
end

return M
