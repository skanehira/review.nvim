-- 起動 scan の worktree 残骸掃除 (pr-worktree.md「異常終了からの回復」、
-- persistence-restore.md「起動時」3: 同じ scan を読む)。
-- 対象は created_by_us=true の記録のある自前作成分のみ (INV-3)。
--   * open + dir 実在 + git 登録済み -> 復元でそのまま再利用 (何もしない)
--   * open + dir 消滅             -> 記録から worktree を外して save
--                                    (復元時の作成判断で再生成 — DoD シナリオ 3)
--   * open + dir 実在 + git 未登録  -> 孤児の作成分。掃除して記録を回収
--   * closed + dir 残骸            -> 「掃除してよい残骸」を通知し prune + dir 削除
-- 処理は slug 昇順の逐次チェーン (掃除の完了を待ってから次。cb は全処理後 1 回)。
local git_worktree = require 'review.git.worktree'
local store = require 'review.store.session'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

local function notify_info(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.INFO)
end

local function dir_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function nullify(session)
  session.worktree = vim.NIL
  local saved = store.save(session)
  if not saved.ok then
    notify_warn(saved.error)
  end
end

-- dir を削って prune する。prune は dir 削除で孤児化した管理登録の掃除
-- (DESIGN.md「既知の制約」worktree 残骸の回収)。失敗は WARN で scan を止めない
-- (残った孤児登録は次回 add 衝突時の prune 回収に任せる)。
-- null_record は open の回復のみ true (復元時の作成判断へ渡す)。closed の残骸掃除で
-- save すると、:Review delete と競合したとき掃除側の save が delete 済み JSON を
-- 復活させる (E2E phase6 で検出した実バグ)。dir 消滅後の closed 記録は
-- classify==skip なのでそのまま残して無害。
local function sweep_dir(session, on_done, null_record)
  local path = session.worktree.path
  if not git_worktree.remove_dir(path) then
    notify_warn(
      ('worktree dir を削除できませんでした (%s): %s'):format(session.id, path)
    )
    on_done()
    return
  end
  git_worktree.prune({ repo = session.repo }, function(res)
    if not res.ok then
      notify_warn(('worktree prune に失敗しました (%s): %s'):format(session.id, res.error))
    end
    if null_record then
      nullify(session)
    end
    on_done()
  end)
end

local function classify(session, registered_set)
  local record = session.worktree
  if record == nil or record == vim.NIL or record.created_by_us ~= true then
    return 'skip' -- 対象外 (INV-3: 自前記録のない worktree には触れない)
  end
  if not dir_exists(record.path) then
    if session.status == 'open' then
      return 'reclaim-record' -- 記録はあるが dir 消滅 open。記録だけ回収する
    end
    return 'skip' -- closed + dir なし = 掃除完了済みの正常状態
  end
  if session.status == 'closed' then
    return 'sweep' -- close 掃除の失敗残骸 (MUST 3 の異常終了側)
  end
  local real = vim.uv.fs_realpath(record.path) or record.path
  return registered_set[real] and 'keep' or 'sweep'
end

--- repo の全セッションを走査し worktree 残骸を掃除する (cb() で完了通知)。
--- git list は open + dir 実在候補があるときだけ実行する (無駄打ちしない)。
function M.sweep(repo, cb)
  local done = cb or function() end

  local sessions = {}
  for _, sess in ipairs(store.list(repo).data) do
    sessions[#sessions + 1] = sess
  end
  table.sort(sessions, function(a, b)
    return a.id < b.id
  end)

  local need_list = false
  for _, sess in ipairs(sessions) do
    local record = sess.worktree
    if
      record ~= nil
      and record ~= vim.NIL
      and record.created_by_us == true
      and sess.status == 'open'
      and dir_exists(record.path)
    then
      need_list = true
    end
  end

  local function process(registered_set)
    local function step(i)
      if i > #sessions then
        done()
        return
      end
      local sess = sessions[i]
      local action = classify(sess, registered_set)
      if action == 'skip' or action == 'keep' then
        step(i + 1)
        return
      end
      if action == 'reclaim-record' then
        notify_info(
          (
            '%s の worktree ディレクトリが消滅しています。'
            .. '記録から worktree を外しました (復元時に作成判断で再生成します)'
          ):format(sess.id)
        )
        nullify(sess)
        step(i + 1)
        return
      end
      local reason = (sess.status == 'closed') and 'close 掃除の失敗残骸' or 'git 未登録'
      notify_warn(
        ('worktree 残骸を掃除しました %s: %s (%s)'):format(
          sess.id,
          sess.worktree.path,
          reason
        )
      )
      -- open の孤児は記録回収 (save) して復元時の再生成へ渡す。closed は dir を
      -- 消すだけ (save すると delete と競合して JSON を復活させ得る — 上の注記)。
      sweep_dir(sess, function()
        step(i + 1)
      end, sess.status == 'open')
    end
    step(1)
  end

  if not need_list then
    process {}
    return
  end
  git_worktree.list({ repo = repo }, function(res)
    local set = {}
    if res.ok then
      for _, p in ipairs(res.data) do
        set[vim.uv.fs_realpath(p) or p] = true
      end
    else
      -- list 不能時の登録可否不明は、掃除を進める材料が無いので keep 側 (触らない)
      -- に倒す = 未知のユーザーデータを scan が黙って消さない安全側 (INV-3 趣旨)。
      for _, sess in ipairs(sessions) do
        local record = sess.worktree
        if
          record ~= nil
          and record ~= vim.NIL
          and record.created_by_us == true
          and sess.status == 'open'
        then
          set[vim.uv.fs_realpath(record.path) or record.path] = true
        end
      end
    end
    process(set)
  end)
end

return M
