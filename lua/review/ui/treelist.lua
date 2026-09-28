-- ui/treelist: file panel のツリーモデル (純ロジック)。docs/design/features/
-- diff-review.md「file panel」/ docs/design/DESIGN.md「file panel 表示」が正本。
-- path 一覧 -> 表示行テーブルの組み立てのみを担当する (-buffer 描画・カーソル・
-- highlight 適用は ui/filepanel)。FS・窓・vim API を触らないので入出力だけで判定できる。
--
-- 行フォーマットの決定 (docs 契約 + 設計の穴埋め):
--   file 行 `[indent][status ][コメントアイコン ][icon ][basename] +a -d`。viewed
--     は行にマークを出さない (Reviewed セクションへの移動で完了が表現される —
--     2026-09 改訂)。コメントありは status の後に nf-cod-comment (U+EA6B) を出す
--     (ReviewPanelComment。旧 💬 は廃止)。
--     ±は `+n` (ReviewPanelAdd 緑) / `-n` (ReviewPanelRemove 赤) の 2 span。
--     親パス grey サフィックスは持たない (ツリーの indent が文脈 — 2026-09 改訂)
--   dir 行 `[indent][▸ ]status display/`。末尾 `/` が dir 識別子 (同名のファイルと
--     dir が同時差分に出るケースの区別規則)。status は配下全 file の集約
--     (全同一記号ならそのまま、種類混在は `*` — 単独 status `M` と衝突させない)
--   単一 dir child 連鎖は連結表示 (`a/b/c/`)。連結行の path キーは deepest dir の
--     canonical path (スラッシュ無し) = collapsed 集合のキーと row_entry の語を一致させる
--   並びは dir 先行 -> file、各々名前昇順 (バイト順)
-- 表示は 2 セクション構成 (2026-09): «Changes (N)» (tree のみ subtitle
--   «Showing changes for: …» 付き) + 未レビュー (viewed=false) の行、空行
--   (kind='separator')、«Reviewed (M)» + レビュー済み (viewed=true) の行。
--   Reviewed は 0 件でも常に出す。viewed は行にマークを出さない (セクションで表現)。
--   list モードも同構成だが subtitle は出さない (compact 契約)。
local M = {}

local INDENT = '  '

local function split_path(path)
  local segs = {}
  for seg in path:gmatch '[^/]+' do
    segs[#segs + 1] = seg
  end
  return segs
end

local function join(segs)
  return table.concat(segs, '/')
end

-- new_dir の子 node を取って無ければ作る
local function child_dir(node, name, parent_path)
  node.dirs = node.dirs or {}
  local dir = node.dirs[name]
  if dir == nil then
    dir = {
      name = name,
      path = parent_path == '' and name or (parent_path .. '/' .. name),
      dirs = {},
      files = {},
    }
    node.dirs[name] = dir
  end
  return dir
end

local function build_tree(files)
  local root = { name = nil, path = '', dirs = {}, files = {} }
  for _, entry in ipairs(files) do
    local segs = split_path(entry.path)
    local node = root
    for i = 1, #segs - 1 do
      node = child_dir(node, segs[i], node.path)
    end
    node.files[segs[#segs]] = entry
  end
  return root
end

-- dir 配下全 file の status 集約 (全同一ならその記号 / 混在は *)
local function aggregate_status(node, acc)
  acc = acc or {}
  for _, entry in pairs(node.files) do
    acc[#acc + 1] = entry.status
  end
  for _, dir in pairs(node.dirs) do
    aggregate_status(dir, acc)
  end
  return acc
end

local function combined_status(statuses)
  local first = statuses[1]
  for _, s in ipairs(statuses) do
    if s ~= first then
      return '*'
    end
  end
  return first
end

-- 行組み立てヘルパ。piece を group なしで足すと区切り space などに使える
-- (spans は意味のある glyph 範囲だけを指す = filepanel がそのまま extmark を張れる)。
local function line()
  local self = { text = '', spans = {} }
  function self.add(piece, group)
    local from = #self.text
    self.text = self.text .. piece
    if group ~= nil then
      self.spans[#self.spans + 1] = { from = from, to = #self.text, group = group }
    end
  end
  return self
end

-- tree モードは basename、list モードはフルパス 1 行 (親パスサフィックスは無し)
-- (name に path を渡す) ので name 解決は呼び出し側。
local function file_row(entry, indent, icon, icon_hl, name)
  local l = line()
  l.add(indent)
  l.add(entry.status, 'ReviewPanelStatus')
  l.add ' '
  if entry.comment then
    l.add('\u{EA6B}', 'ReviewPanelComment')
    l.add ' '
  end
  if icon ~= nil then
    -- アイコンとファイル名の色の hl group の解決は resolver の責任
    -- (nvim-web-devicons の DevIcon* group 参照のみ。plugin 側で set_hl も
    -- syntax engine も触らない — diffview hl.get_file_icon と同方式)。
    -- hl なし / 未定義 group は無色 = ReviewPanelFile フォールバック。
    l.add(icon .. ' ', icon_hl)
  end
  l.add(name, icon_hl or 'ReviewPanelFile')
  l.add ' '
  l.add(('+%d'):format(entry.added or 0), 'ReviewPanelAdd')
  l.add ' '
  l.add(('-%d'):format(entry.deleted or 0), 'ReviewPanelRemove')
  return { kind = 'file', text = l.text, path = entry.path, spans = l.spans }
end

-- 連結チェーンを進む末尾 node と表示名 (a -> b -> c なら c と "a/b/c")
local function merge_chain(dir)
  local names = { dir.name }
  local node = dir
  while node.files and next(node.files) == nil and node.dirs and next(node.dirs) ~= nil do
    local only = nil
    local count = 0
    for name, child in pairs(node.dirs) do
      count = count + 1
      only = { name = name, child = child }
    end
    if count ~= 1 then
      break
    end
    node = only.child
    names[#names + 1] = only.name
  end
  return node, join(names)
end

local function sorted_children(node)
  local names = {}
  for name in pairs(node.dirs) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function sorted_files(node)
  local names = {}
  for name in pairs(node.files) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function emit_tree(node, opts, indent, out)
  -- dir 先行 -> file、名前昇順 (単一 child 連鎖は連結)
  for _, name in ipairs(sorted_children(node)) do
    local leaf, display = merge_chain(node.dirs[name])
    local collapsed = opts.collapsed[leaf.path] == true
    local status = combined_status(aggregate_status(leaf))
    local l = line()
    l.add(indent)
    if collapsed then
      l.add('▸', 'ReviewPanelDir')
      l.add ' '
    end
    l.add(status, 'ReviewPanelStatus')
    l.add ' '
    l.add(display .. '/', 'ReviewPanelDir')
    out[#out + 1] = {
      kind = 'dir',
      text = l.text,
      path = leaf.path,
      collapsed = collapsed,
      spans = l.spans,
    }
    if not collapsed then
      -- 連結で消費した階層ぶんインデントを進める
      -- (file 行のインデント = path の階層数と一致する)
      local depth = 0
      for _ in display:gmatch '[^/]+' do
        depth = depth + 1
      end
      emit_tree(leaf, opts, indent .. (INDENT):rep(depth), out)
    end
  end
  for _, fname in ipairs(sorted_files(node)) do
    local entry = node.files[fname]
    local icon, icon_hl = nil, nil
    if opts.icon ~= nil then
      icon, icon_hl = opts.icon(entry.path)
    end
    out[#out + 1] = file_row(entry, indent, icon, icon_hl, fname)
  end
end

--- viewed で 2 分割 (Changes セクション / Reviewed セクション)。入力を path 昇順のまま
--- 保った上で、viewed=true の file を Reviewed 側へ移す (各セクション内は昇順維持)。
local function split_viewed(sorted)
  local changes, reviewed = {}, {}
  for _, entry in ipairs(sorted) do
    if entry.viewed then
      reviewed[#reviewed + 1] = entry
    else
      changes[#changes + 1] = entry
    end
  end
  return changes, reviewed
end

local function header(text)
  return { kind = 'header', text = text, spans = {} }
end

local function separator()
  return { kind = 'separator', text = '', spans = {} }
end

-- セクション (Changes / Reviewed) の内容行を組み立てる。mode='tree' はツリー、
-- 'list' はフルパス 1 行のフラット形式 (subtitle は出さない — list は compact 契約)。
-- title は見出し文字列 («Changes (N)» / «Reviewed (M)»)。
local function emit_section_rows(section, opts, rows, title, with_subtitle)
  rows[#rows + 1] = header(title)
  if opts.mode ~= 'list' then
    if with_subtitle then
      rows[#rows + 1] =
        header(('Showing changes for: %s..%s'):format(opts.base or '', opts.head_display or ''))
    end
    emit_tree(build_tree(section), opts, '', rows)
  else
    -- フラット形式 (フルパス 1 行)。親パスサフィックスは付けない (path 自体がフル)
    for _, entry in ipairs(section) do
      local icon_hl = nil
      if opts.icon ~= nil then
        local _, hl = opts.icon(entry.path)
        icon_hl = hl
      end
      rows[#rows + 1] = file_row(entry, '', nil, icon_hl, entry.path)
    end
  end
end

--- files -> 表示行テーブル。
--- files: { {path, status, added, deleted, viewed} } (viewed は呼び出し側が session から解決)
--- opts = {
---   mode = 'tree' | 'list' (省略時 tree),
---   collapsed = { [dirpath]=true } (dir 行の path キー = deepest path),
---   icon = nil | function(path) -> (string|nil), (hlname|nil) (2返り値 = 色 group),
---   base, head_display  -- tree ヘッダ «Showing changes for: <base>..<head 表示名>»
--- }
--- 返り値 rows = { {kind='header'|'separator'|'dir'|'file', text, path?, spans} }
--- 構成: «Changes (N)» + (tree のみ) «Showing changes for: …» + 未レビューのツリー /
--- flat 行 + 空行 (separator) + «Reviewed (M)» + レビュー済みのツリー / flat 行。
--- Reviewed は 0 件でも常に出し、表示 file 0 件のときはヘッダも出さない
--- (従来 «一致 0 件は 0 行一覧» 契約のまま)。
function M.build(files, opts)
  opts = opts or {}
  opts.collapsed = opts.collapsed or {}
  local sorted = {}
  for _, entry in ipairs(files) do
    sorted[#sorted + 1] = entry
  end
  table.sort(sorted, function(a, b)
    return a.path < b.path
  end)

  if #sorted == 0 then
    return {}
  end
  local changes, reviewed = split_viewed(sorted)
  local rows = {}
  -- Changes セクション (subtitle は tree モードのみ。list は flat で compact)
  emit_section_rows(changes, opts, rows, ('Changes (%d)'):format(#changes), true)
  -- Reviewed セクション (常に表示。空行で区切る。subtitle は出さない)
  rows[#rows + 1] = separator()
  emit_section_rows(reviewed, opts, rows, ('Reviewed (%d)'):format(#reviewed), false)
  return rows
end

--- panel 絞り込み (大文字小文字無視の path 部分一致)。nil/空 = そのまま (コピー)。
--- render 側と ]d/[d の進行順が同じ集合を向くため可視一覧はこの 1 関数に閉じる。
function M.visible(files, needle)
  if needle == nil or needle == '' then
    local copy = {}
    for i, entry in ipairs(files) do
      copy[i] = entry
    end
    return copy
  end
  local lower = needle:lower()
  local out = {}
  for _, entry in ipairs(files) do
    if entry.path:lower():find(lower, 1, true) ~= nil then
      out[#out + 1] = entry
    end
  end
  return out
end

return M
