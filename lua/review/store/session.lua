-- セッション JSON の読書・アトミック書込・退避
-- (docs/design/features/persistence-restore.md「入出力と振る舞い」保存 / 読込、
-- DESIGN.md「データスキーマ」「横断規約」永続化)。
-- 書き込みは同一ディレクトリの tmp に全量書いて os.rename で差し替える。
-- 破損 / version 不一致は .corrupt へ退避してから「存在しない」扱い + WARN。
-- 実在するが読めないファイルは退避せず WARN だけ出して「存在しない」扱い。
-- 外界 (os.rename / os.time / vim.notify、paths 経由の stdpath) は DI 注入可能。

local result = require 'review.core.result'
local paths = require 'review.store.paths'

local M = {}

-- DESIGN.md「データスキーマ」の schema version。save は store 正本として
-- 書き込みコピーの version をこの値で正規化する。
local SCHEMA_VERSION = 1

local rename = os.rename
local now = os.time
local notify = vim.notify

-- nil を渡すと本物へ戻す (git/cli.lua と同じ注入形態)。
function M._set_rename(fn)
  rename = fn or os.rename
end

function M._set_now(fn)
  now = fn or os.time
end

function M._set_notify(fn)
  notify = fn or vim.notify
end

-- 同期読み取り (vim.fn.readfile は読めないファイルで例外を投げるため pcall。
-- 例外を結果型・不在扱いへ変換するアダプタ境界 — DESIGN.md 横断規約)。
-- 実在するが読めない (権限等) は退避せず WARN だけ出す: .corrupt へ退避しても
-- 同じ読取問題で退避先が読めず隔離の意味がない。stat で存在を確認できない
-- 失敗は真の不在と同じく「存在しない」扱いで無通知 (persistence-restore.md「読込」)。
local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok then
    return lines
  end
  if vim.uv.fs_stat(path) ~= nil then
    notify(
      ('review.nvim: セッションファイル %s が読み取れません。「存在しない」として扱います'):format(
        path
      ),
      vim.log.levels.WARN
    )
  end
  return nil
end

-- 破損退避。rename 失敗 (退避先への書き込み権限など) でも WARN して
-- 「存在しない」扱いのままにする (レビュー不能にしない。退避は best effort)。
local function quarantine(repo, slug, file, cause)
  local corrupt = paths.corrupt_file(repo, slug)
  rename(file, corrupt)
  notify(
    ('review.nvim: %s のセッションファイル %s を %s に退避しました'):format(
      cause,
      file,
      corrupt
    ),
    vim.log.levels.WARN
  )
end

-- 1 ファイルを読んでスキーマ検証したセッションを返す。
-- 不在 / 読取不能 / 退避実施時は nil。パース失敗と version 不一致は .corrupt
-- 退避 + WARN、読取不能 (実在・読めない) は退避せず WARN (read_lines 参照)。
local function read_session(repo, slug)
  local file = paths.session_file(repo, slug)
  local lines = read_lines(file)
  if lines == nil then
    return nil -- 不在 (無通知) / 読み取り不能 (WARN 済み)。いずれも退避は行わない
  end

  local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not ok_decode or type(decoded) ~= 'table' then
    quarantine(repo, slug, file, '破損 JSON')
    return nil
  end
  if decoded.version ~= SCHEMA_VERSION then
    local cause = ('schema version 不一致 (version=%s)'):format(tostring(decoded.version))
    quarantine(repo, slug, file, cause)
    return nil
  end
  return decoded
end

-- セッションを即時・アトミックに永続化する (INV-4)。
-- 呼び出し側のテーブルは変更しない: updated_at 更新と version 正規化は
-- 書き込みコピーに行う。失敗 (作成・書込・rename 不能) は E_STORE を返し、
-- ディスクは前回内容を維持する (メモリ上の状態は呼び出し側が保ち、
-- 次の save で再挑戦する — persistence-restore.md「保存」)。
function M.save(sess)
  local dir = paths.repo_dir(sess.repo)
  if vim.fn.mkdir(dir, 'p') == 0 then
    return result.err(
      'セッションディレクトリを作成できません: ' .. dir,
      result.codes.E_STORE
    )
  end

  local file = paths.session_file(sess.repo, sess.id)
  local tmp = file .. '.tmp'
  local payload = vim.deepcopy(sess)
  payload.version = SCHEMA_VERSION
  payload.updated_at = now()

  local f = io.open(tmp, 'wb')
  if f == nil then
    return result.err(
      'セッションファイルを書けません: ' .. tmp,
      result.codes.E_STORE
    )
  end
  local written, write_err = f:write(vim.json.encode(payload))
  f:close()
  if written == nil then
    return result.err(
      ('セッションファイルの書き込みに失敗しました: %s (%s)'):format(
        tmp,
        tostring(write_err)
      ),
      result.codes.E_STORE
    )
  end

  local renamed, rename_err = rename(tmp, file)
  if not renamed then
    return result.err(
      ('セッションファイルの差し替えに失敗しました: %s (%s)'):format(
        file,
        tostring(rename_err)
      ),
      result.codes.E_STORE
    )
  end
  return result.ok()
end

-- 保存済みセッションを読む。不在 (読取不能・退避実施含む) は data nil の ok、
-- すなわち「存在しない」扱いで返す (persistence-restore.md「読込」)。
function M.load(repo, id)
  return result.ok(read_session(repo, id))
end

-- 当該 repo の保存済みセッション全件 (status 問わず。:Review list 用)。
-- 返り順は未規定。.corrupt と非 .json は読まない。repo ディレクトリ
-- 未作成なら空配列。
function M.list(repo)
  local out = {}
  local scandir = vim.uv.fs_scandir(paths.repo_dir(repo))
  if scandir ~= nil then
    while true do
      local name = vim.uv.fs_scandir_next(scandir)
      if name == nil then
        break
      end
      if name:sub(-5) == '.json' then
        local sess = read_session(repo, name:sub(1, -6))
        if sess ~= nil then
          out[#out + 1] = sess
        end
      end
    end
  end
  return result.ok(out)
end

-- 保存済みセッション ファイルの削除 (:Review delete)。存在しない id は
-- 目標状態 (不存在) そのものなので ok (persistence-restore.md「実装の配置」
-- delete(repo, id))。.corrupt は隔離済み別ファイルなので触らない。
function M.delete(repo, id)
  local file = paths.session_file(repo, id)
  local removed, err = os.remove(file)
  if removed == nil then
    -- ENOENT は成功として扱う (errno 文字列の判定は環境非依存な接頭辞で行う)
    if not tostring(err):match 'No such file' then
      return result.err(
        ('セッションファイルの削除に失敗しました: %s (%s)'):format(
          file,
          tostring(err)
        ),
        result.codes.E_STORE
      )
    end
  end
  return result.ok()
end

return M
