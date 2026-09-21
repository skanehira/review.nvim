-- worktree dir に紐づく実ファイルバッファの走査ヘルパー (E211 対策と dirty 判定)。
-- dir を消す全経路 (close / delete / 開始時掃除 / 起動 scan の sweep) は remove の
-- spawn より先に destroy を呼ぶ責務を持つ (pr-worktree.md「dir を消す全経路」契約)。
-- session と health の両方から必要になるため handlers 共通の場所に置く
-- (health は session を require しない = 循環なし)。
local M = {}

-- dir 配下の path か (両側を fs_realpath に通して比較する — bufadd は symlink
-- 解決後の名前を buffer 名に持ち、記録された worktree path は未正規化
-- (DESIGN「既知の制約」。macOS /var -> /private/var で一致しなくなる)。
-- 実在しないファイルの buffer は realpath が nil に落ちるため、素の名前同士の
-- 比較も併用する (raw vs raw / real vs real の 4 組合せで一致を見る)。
local function is_under_dir(dir, name)
  local function strip(p)
    return (p:gsub('/+$', ''))
  end
  local dirs = { strip(dir) }
  local dreal = vim.uv.fs_realpath(dir)
  if dreal ~= nil then
    dirs[#dirs + 1] = strip(dreal)
  end
  local names = { strip(name) }
  local nreal = vim.uv.fs_realpath(name)
  if nreal ~= nil then
    names[#names + 1] = strip(nreal)
  end
  for _, d in ipairs(dirs) do
    for _, n in ipairs(names) do
      if n:sub(1, #d + 1) == d .. '/' then
        return true
      end
    end
  end
  return false
end

-- worktree 配下を指す実ファイルバッファを単体で破棄する (E211 対策)。
-- Neovim 0.13 は 'autoread' (既定 on) のもとで loaded な全バッファに fs watcher
-- を張るため (:help timestamp)、dir を消したあとに loaded バッファが残ると
-- E211: File "..." no longer available が飛ぶ。dir を消す全経路は remove より
-- 先に同期でこれを呼ぶ責務を持つ。
-- 選択は nvim_list_bufs() の名前走査 (active.owned_bufs は open_head_real を
-- 通った分しか載らず、ユーザーが :edit / LSP ジャンプで開いた分を取りこぼす)。
-- session の close_buffer は流用しない — あれは win_findbuf の全窓を先に閉じるため、
-- 別 tab で同じファイルを開いていたユーザー窓まで消える。バッファだけ消せばその窓は
-- 代替バッファへ張り替わり、レイアウトは壊れない。
function M.destroy(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and name:match '^review://' == nil and is_under_dir(path, name) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
end

-- worktree 配下の modified (未保存) バッファ数 (close / delete の --force 確認に
-- 乗せる分。git status はディスクのみを見るため、バッファ上の未保存編集はここで数える)。
function M.count_modified(path)
  local n = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and is_under_dir(path, name) then
        n = n + 1
      end
    end
  end
  return n
end

return M
