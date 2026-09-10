-- git / gh の stderr を「何が起きたか + 次の行動」が伝わるユーザー向け文言に
-- 寄せる (UX review F4 / F19: 生 stderr の丸出しは最も頻出の誤入力に対する
-- 応答として機能していなかった)。該当パターンなしは原文をそのまま返す —
-- 未知のエラー情報を翻訳の建前で握りつぶさない。
local M = {}

--- 解決不能な ref を指す git 失敗 (誤字ブランチが最頻) を翻訳する。
--- 対象: fatal: bad revision 'x' / unknown revision 'x' / ambiguous argument
--- 'x' / not a valid object name 'x' など 'x' を quote して名を出す形。
function M.git_ref_error(err)
  local text = err or ''
  local name = text:match "revision '([^']+)'"
    or text:match "object name '([^']+)'"
    or text:match "ambiguous argument '([^']+)'"
  if name == nil then
    return err
  end
  return (
    "レビュー対象 ref が解決できません: '%s'。存在するブランチ/コミットを"
    .. '指定してください (start の base/head 引数は <Tab> で補完できます)'
  ):format(name)
end

--- gh 失敗の定訳。no git remotes found (remote 無 repo で :Review pr)、
--- PR 番号が解決できない系。
function M.gh_error(err)
  local text = err or ''
  if text:match 'no git remote' then
    return 'このリポジトリに git remote (origin 等) がありません。:Review pr は GitHub のリモートリポジトリでのみ利用できます'
  end
  local number = text:match '[Cc]ould not resolve any? pull request (%S+)'
  if number ~= nil then
    return ('PR %s が見つかりません。番号 (または :Review pr <URL>) を gh pr list で確認できる値にしてください'):format(
      number
    )
  end
  return err
end

return M
