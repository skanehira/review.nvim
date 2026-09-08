-- anchor 検証 (persistence-restore.md「anchor 検証」)。純粋ロジック:
-- 保存済みの Comments を new 側再取得差分 (core/diff の parse 結果) と突き合わせ、
-- 位置補正 / state を in-place で更新する。
-- 層制約: handlers(session)/handlers(restore) 両方から使われるため、上から下へ
-- の依存方向を保つ core に置く (restore 同士の循環 require 回避 — 配置は
-- docs/design/features/persistence-restore.md の更新で追記)。
-- 判定规则 (文書準拠):
--   (a) 保存行の新側テキスト == anchor.line -> active
--   (b) ±20 行以内に一致 -> active + 行数補正 (最近接優先、同距離は前)
--   (c) 見つからない -> outdated (line / end_line は保存値のまま保持)
-- 照合は新側差分に可視な行 (add/context) のみ — 変換はパーサ起点の 1 系統
-- (DESIGN.md「既知の制約」)。
local M = {}

-- File -> { [new_line] = text } (add/context の可視行のみ)。
local function text_map(file)
  local map = {}
  if file == nil then
    return map
  end
  for _, hunk in ipairs(file.hunks) do
    for _, line in ipairs(hunk.lines) do
      if line.new_line ~= nil then
        map[line.new_line] = line.text
      end
    end
  end
  return map
end

local ANCHOR_WINDOW = 20

local function anchor_line(comment)
  local anchor = comment.anchor
  if anchor == nil or anchor == vim.NIL or anchor.line == nil or anchor.line == vim.NIL then
    return nil
  end
  return anchor.line
end

--- comments を files_by_path に対して検証し、位置補正・state を更新する。
--- anchor 欠損 (nil / vim.NIL) は検証不能として active のまま据え置く。
function M.verify(comments, files_by_path)
  local maps = {}
  for _, c in ipairs(comments) do
    if maps[c.file] == nil then
      maps[c.file] = text_map(files_by_path[c.file])
    end
    local texts = maps[c.file]
    local want = anchor_line(c)
    if want ~= nil then
      local shift, found = nil, nil
      if texts[c.line] == want then
        shift, found = 0, c.line
      else
        for d = 1, ANCHOR_WINDOW do
          if texts[c.line - d] == want then
            shift, found = -d, c.line - d
            break
          elseif texts[c.line + d] == want then
            shift, found = d, c.line + d
            break
          end
        end
      end
      if shift ~= nil then
        c.line = found
        c.end_line = c.end_line + shift
        c.state = 'active'
      else
        c.state = 'outdated'
      end
    end
  end
end

return M
