-- handlers/usermsg: git/gh stderr -> ユーザー向け文言 (UX review F4/F19)。
-- 翻訳は「名前 + 次の行動」を含み、該当パターンなしは原文 passthrough
-- (未知エラーの情報を落とさない契约)。
local usermsg = require 'review.handlers.usermsg'

describe('usermsg.git_ref_error', function()
  it('bad / unknown revision を 名前と補完導線のある文言へ寄せる', function()
    for _, raw in ipairs {
      "fatal: bad revision 'nope'",
      "fatal: unknown revision 'nope'",
      "fatal: ambiguous argument 'nope': unknown revision or path not in the working tree",
      "fatal: invalid object name 'nope'",
    } do
      local msg = usermsg.git_ref_error(raw)
      assert.is_true(msg:find("'nope'", 1, true) ~= nil, raw .. ' -> ' .. msg)
      assert.is_true(msg:find('<Tab>', 1, true) ~= nil, raw .. ' -> ' .. msg)
    end
  end)

  it('ref 系でない git エラーは原文のまま (情報loss防止)', function()
    local raw = 'fatal: not a git repository'
    assert.equals(raw, usermsg.git_ref_error(raw))
    assert.is_nil(usermsg.git_ref_error(nil))
  end)
end)

describe('usermsg.gh_error', function()
  it('no git remotes found を 日本語 + 対処へ', function()
    local msg = usermsg.gh_error 'no git remotes found'
    assert.equals(
      'このリポジトリに git remote (origin 等) がありません。:Review pr は GitHub のリモートリポジトリでのみ利用できます',
      msg
    )
  end)

  it('PR 解決不能は番号を添えて gh pr list 導線へ', function()
    local msg = usermsg.gh_error 'Could not resolve any pull request #42'
    assert.is_true(msg:find('42', 1, true) ~= nil)
    assert.is_true(msg:find('gh pr list', 1, true) ~= nil)
  end)

  it('既知パターンの gh 失敗 (未ログイン等) は原文 passthrough', function()
    local raw = 'gh 未ログインです。`gh auth login` を実行してください'
    assert.equals(raw, usermsg.gh_error(raw))
  end)
end)
