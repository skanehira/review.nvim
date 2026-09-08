-- git diff 生出力 (git diff <base> <head> の stdout) のパーサ。
-- DESIGN.md「既知の制約」: new 側行番号への変換 (hunk ヘッダ `@@ -a,b +c,d @@` の
-- c 起点の累計) はこのファイルの 1 箇所にのみ置く。下流 (UI/handlers) は
-- parse 結果の new_line を参照するだけで行番号を独自計算しない。
--
-- 出力構造 (files: 実 git の出現順):
--   File  = { path, status='A'|'M'|'D'|'R', binary, added, deleted, hunks }
--   Hunk  = { old_start, old_count, new_start, new_count, header, lines }
--   Line  = { kind='add'|'del'|'context', text, new_line?=number }
--     new_line は new 側に存在する行 (add/context) のみ。del 行と
--     削除専用 hunk (new_count=0 では add/context 行が現れない) では付与されない。
-- 「\ No newline at end of file」マーカー行は File/Line に含まない。
local M = {}

-- '@@ -a[,b] +c[,d] @@ [section]' のヘッダ行か。マッチなら両側の範囲文字列を返す。
local function match_hunk_header(line)
  return line:match '^@@ %-([%d,]+) %+([%d,]+) @@'
end

-- '1,5' / '5' を (start, count) に。行数 1 の省略は count=1 (git 2.55 実測, -U0 でも同じ)。
local function parse_range(text)
  local comma = text:find(',', 1, true)
  if comma == nil then
    return tonumber(text), 1
  end
  return tonumber(text:sub(1, comma - 1)), tonumber(text:sub(comma + 1))
end

local function starts_with(line, prefix)
  return line:sub(1, #prefix) == prefix
end

-- 'a/path' / 'b/path' のプレフィックス剥がし。'/dev/null' は呼び出し側で除いて渡す。
local function strip_side_prefix(value)
  return (value:gsub('^a/', '', 1):gsub('^b/', '', 1))
end

-- ファイルレコードの構築中ステート。path は finalise 時点で優先順位により確定する:
-- rename to > +++ (新パス) > --- (旧パス) > `diff --git` 行の新側。
-- 空ファイルの新規/削除やモード変更のみでは ---/+++ 行自体が存在しない
-- (git 2.55 実測) ため、最終手段として diff --git 行へ退避する。
local function new_file_state(header_line)
  local rest = header_line:sub(#'diff --git ' + 1)
  return {
    fallback_path = rest:match ' b/(.+)$',
    new_path = nil,
    old_path = nil,
    renamed_to = nil,
    new_file_mode = false,
    deleted_file_mode = false,
    binary = false,
    hunks = {},
  }
end

local function finalise(state)
  if state == nil then
    return nil
  end
  local path = state.renamed_to or state.new_path or state.old_path or state.fallback_path
  local status = 'M'
  if state.new_file_mode then
    status = 'A'
  elseif state.deleted_file_mode then
    status = 'D'
  elseif state.renamed_to then
    status = 'R'
  end
  local added, deleted = 0, 0
  for _, hunk in ipairs(state.hunks) do
    for _, line in ipairs(hunk.lines) do
      if line.kind == 'add' then
        added = added + 1
      elseif line.kind == 'del' then
        deleted = deleted + 1
      end
    end
  end
  if path == nil then
    return nil
  end
  local hunks = {}
  for i, hunk in ipairs(state.hunks) do
    -- new_next は構築中の作業値なので出力へ漏らさない (spec の全体比較で
    -- 異物混入を検出するため、公開は契約キーのみ)。
    hunks[i] = {
      old_start = hunk.old_start,
      old_count = hunk.old_count,
      new_start = hunk.new_start,
      new_count = hunk.new_count,
      header = hunk.header,
      lines = hunk.lines,
    }
  end
  return {
    path = path,
    status = status,
    binary = state.binary,
    added = added,
    deleted = deleted,
    hunks = hunks,
  }
end

-- hunk 本文行 ('+' / '-' / ' ' / 改行なしマーカー) を直近の hunk へ取り込む。
-- new 側行番号は行種別だけで決まり、カウンタは new_start から add/context 行分行進する
-- (DESIGN.md 既知の制約「パーサの 1 箇所のみに置く」の本体)。
local function consume_body_line(hunk, line)
  local marker = line:sub(1, 1)
  if marker == '\\' then
    return -- 「\ No newline at end of file」マーカーは行として数えない
  end
  local entry
  if marker == '+' then
    entry = { kind = 'add', text = line:sub(2), new_line = hunk.new_next }
    hunk.new_next = hunk.new_next + 1
  elseif marker == '-' then
    entry = { kind = 'del', text = line:sub(2) }
  else
    entry = { kind = 'context', text = line:sub(2), new_line = hunk.new_next }
    hunk.new_next = hunk.new_next + 1
  end
  table.insert(hunk.lines, entry)
end

--- git diff の生出力をパースして File の一覧へ変換する (純粋関数)。
function M.parse(text)
  local files = {}
  local file = nil -- 構築中の File (diff --git 行で開く)
  local hunk = nil -- 直近に開かれた hunk (本文行の受け皿)
  local in_hunk = false

  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local consumed = false
    if in_hunk then
      local marker = line:sub(1, 1)
      if marker == '+' or marker == '-' or marker == ' ' or marker == '\\' then
        consume_body_line(hunk, line)
        consumed = true
      else
        -- 本文以外 (diff --git / @@ / ヘッダ群) が来たら hunk 終端。同じ行を
        -- 構造行として再判定する。
        in_hunk = false
        hunk = nil
      end
    end

    if not consumed then
      if starts_with(line, 'diff --git ') then
        local done = finalise(file)
        if done then
          table.insert(files, done)
        end
        file = new_file_state(line)
      elseif file ~= nil and match_hunk_header(line) then
        local old_start, old_count = parse_range((line:match '^@@ %-([%d,]+)'))
        local new_start, new_count = parse_range((line:match '^@@ .- %+([%d,]+)'))
        hunk = {
          old_start = old_start,
          old_count = old_count,
          new_start = new_start,
          new_count = new_count,
          header = line,
          lines = {},
          new_next = new_start,
        }
        table.insert(file.hunks, hunk)
        in_hunk = true
      elseif file ~= nil then
        -- 構造行 (diff --git / @@) 以外で本文でもない行はファイルヘッダ部。
        -- index / similarity / old mode 等その他ヘッダ行は parse 対象外。
        if starts_with(line, 'new file mode ') then
          file.new_file_mode = true
        elseif starts_with(line, 'deleted file mode ') then
          file.deleted_file_mode = true
        elseif starts_with(line, 'rename to ') then
          -- rename from (旧パス) は意図的に無視 — 旧パスとの対応表示はしない
          -- (diff-review.md「エッジケースの決定」)。
          file.renamed_to = line:sub(#'rename to ' + 1)
        elseif starts_with(line, 'Binary files ') then
          file.binary = true
        elseif starts_with(line, '+++ ') then
          local value = line:sub(5)
          if not starts_with(value, '/dev/null') then
            file.new_path = strip_side_prefix(value)
          end
        elseif starts_with(line, '--- ') then
          local value = line:sub(5)
          if not starts_with(value, '/dev/null') then
            file.old_path = strip_side_prefix(value)
          end
        end
      end
      -- file == nil のままの行 (先頭 diff --git 以前のゴミ行) は読み飛ばす
    end
  end

  local last = finalise(file)
  if last then
    table.insert(files, last)
  end
  return files
end

return M
