-- コメントモデル (DESIGN.md「データスキーマ」Comment 定義)。
-- session の comments 配列に対する追加・編集・削除・カーソル行検索と、
-- id 採番 (c<n> / 既存 max+1)・range 正規化の純粋ロジック。
-- 採番も正規化もこの 1 箇所に集約する (INV-2 の range 条件は呼び出し側
-- = レビュー UI が差分側行番号から作る input を正規化して受け取る)。
-- 時刻 (created_at) は model で取らず attrs で受け取る (外界 DI)。
-- PR レビューの GitHub 連携 (pr-comments) で追加されたフィールド:
--   origin ('local' | 'gh') / gh_id / gh_user / gh_state / in_reply_to /
--   subject_type ('line' | 'file'。file は line/end_line を持たない)
-- は全て optional (後方互換。branch セッションの旧スキーマはそのまま)。
local M = {}

-- ISO8601 (GitHub API の created_at、常に Z = UTC) を epoch seconds へ。解釈不能は 0。
-- vim.fn.strptime はローカル TZ 依存 (macOS と Linux で結果が変わる実測)、
-- os.time のテーブル解釈も TZ 依存なので、days_from_civil による純計算で決定的に求める。
local function days_from_civil(y, m, d)
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = m + (m > 2 and -3 or 9)
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function gh_created_at(iso)
  local y, mo, d, h, mi, s = iso:match '^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z$'
  if not y then
    return 0
  end
  y, mo, d, h, mi, s =
    tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
  return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
end

--- ファイルレベルコメント (subject_type == 'file') かどうか。
function M.is_file_level(c)
  return c.subject_type == 'file'
end

--- 公開: GitHub API の created_at (ISO8601) を epoch seconds に (突合側の
--- 一般コメント正規化でも使う)。
function M.gh_time(iso)
  return gh_created_at(iso)
end

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
--- attrs: { file, line?, end_line?, body, anchor?, created_at, subject_type?,
---         origin?, gh_id?, gh_user?, gh_state?, in_reply_to? }。
--- id/state/end_line はここで付与・正規化するため attrs の同名キーは使わない。
--- subject_type='file' は行を持たない (line/end_line は nil)。それ以外は
--- line を正規化して保持する (既存契約)。
--- anchor は DESIGN.md スキーマの { before, line, after } を呼び出し側の値のまま保持する。
function M.add(comments, attrs)
  local created
  if attrs.subject_type == 'file' then
    created = {
      id = M.new_id(comments),
      file = attrs.file,
      subject_type = 'file',
      body = attrs.body,
      state = 'active',
      created_at = attrs.created_at,
    }
  else
    local line, end_line = M.normalize_range(attrs.line, attrs.end_line)
    created = {
      id = M.new_id(comments),
      file = attrs.file,
      line = line,
      end_line = end_line,
      body = attrs.body,
      anchor = attrs.anchor,
      state = 'active',
      created_at = attrs.created_at,
    }
  end
  -- GitHub 連携の metadata は指定時のみ載せる (旧スキーマのコメントに
  -- origin 等を後から足さない = 保存 JSON が不必要に膨らまない)。
  for _, key in ipairs { 'origin', 'gh_id', 'gh_user', 'gh_state', 'in_reply_to' } do
    if attrs[key] ~= nil then
      created[key] = attrs[key]
    end
  end
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

--- comments の全件を in-place で空にし、削除件数を返す (:Review clear /
--- 一括削除 `D` の本体。state 無関係 = outdated も消える — 二度と prompt に
--- 載らない残骸も一緒に掃除するため)。呼び出し側 (handlers) は 1 回の
--- commit_comment_change で永続化・再描画をまとめる。
function M.remove_all(comments)
  local n = #comments
  for i = n, 1, -1 do
    comments[i] = nil
  end
  return n
end

--- ファイル内で new 側ファイル行 line を range [line..end_line] に含む
--- コメントを保持順で返す (diff キーマップ e / d の「カーソル行のコメント」)。
--- 単一キーの場合は find_at(comments, file, line)[1] で取る。
--- ファイルレベル (行を持たない) は対象外。
function M.find_at(comments, file, line)
  local found = {}
  for _, c in ipairs(comments) do
    if
      not M.is_file_level(c)
      and c.file == file
      and c.line ~= nil
      and c.line <= line
      and line <= c.end_line
    then
      table.insert(found, c)
    end
  end
  return found
end

--- 行スレッドのコメント群を返す。行スレッドの表示 anchor は range の
--- 最終行 (min(end_line)) なので、その行を共有するコメント = 1 スレッド。
--- ファイルレベルは対象外 (file_thread を使う)。
function M.thread_at(comments, file, line)
  local found = {}
  for _, c in ipairs(comments) do
    if not M.is_file_level(c) and c.file == file and (c.end_line or c.line) == line then
      table.insert(found, c)
    end
  end
  return found
end

--- ファイルレベルのコメント群を返す (表示は head 窓の 1 行目上)。
function M.file_thread(comments, file)
  local found = {}
  for _, c in ipairs(comments) do
    if M.is_file_level(c) and c.file == file then
      table.insert(found, c)
    end
  end
  return found
end

--- 返信 (r) の posting 対象。スレッド (行 or ファイルレベル) の「根」を
--- 返す: gh の根コメント (in_reply_to=nil の gh) があればその gh_id (number)、
--- 無ければローカルスレッドの根コメント id (string 'c<n>')。push 済みの
--- ローカル根は gh_id を持っているのでそれを返す。
--- スレッドが無ければ nil。
function M.reply_target(comments, file, line)
  local group
  if line == nil then
    group = M.file_thread(comments, file)
  else
    group = M.thread_at(comments, file, line)
  end
  for _, c in ipairs(group) do
    if c.origin == 'gh' and c.in_reply_to == nil then
      return c.gh_id
    end
  end
  for _, c in ipairs(group) do
    if c.in_reply_to == nil then
      return c.gh_id or c.id
    end
  end
  return nil
end

--- GitHub REST の review comment オブジェクト (GET pulls/{n}/comments の 1 件)
--- を Comment 相当の plain table に正規化する。opts = { id = ローカル採番 id }。
--- state / gh_state は突合 (handlers/pr_comments) が後付けする (ここでは触れない)。
function M.from_gh(gh, opts)
  local c = {
    id = opts.id,
    file = gh.path,
    body = gh.body or '',
    origin = 'gh',
    gh_id = gh.id,
    gh_user = (gh.user or {}).login,
    in_reply_to = gh.in_reply_to_id,
    created_at = gh_created_at(gh.created_at),
    state = 'active',
  }
  if gh.subject_type == 'file' then
    c.subject_type = 'file'
  elseif gh.line ~= nil then
    c.line = gh.line
    c.end_line = gh.line
  else
    -- 現在の diff に対応行が無いコメント (outdated)。突合側が state を
    -- 再検証するため、行は original_line を仮置きする。
    c.line = gh.original_line
    c.end_line = gh.original_line
  end
  return c
end

return M
