local result = require 'review.core.result'

describe('result.ok', function()
  it('data を保持した ok 結果を作る', function()
    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { stdout = 'abc', code = 0 },
    }, result.ok { stdout = 'abc', code = 0 })
  end)

  it('data 無しでも ok=true の結果を作る', function()
    assert.same({ __class = 'review.Result', ok = true }, result.ok())
  end)
end)

describe('result.err', function()
  it('メッセージとコードを保持した err 結果を作る', function()
    assert.same({
      __class = 'review.Result',
      ok = false,
      error = 'fatal: not a git repository',
      code = 'E_GIT',
    }, result.err('fatal: not a git repository', result.codes.E_GIT))
  end)

  it(
    'エラーコードは DESIGN.md 横断規約の 8 種が名前と文字列一致で揃う',
    function()
      assert.same({
        E_GIT = 'E_GIT',
        E_GH = 'E_GH',
        E_REF = 'E_REF',
        E_PR = 'E_PR',
        E_WORKTREE = 'E_WORKTREE',
        E_STORE = 'E_STORE',
        E_CANCELLED = 'E_CANCELLED',
        E_NOT_ACTIVE = 'E_NOT_ACTIVE',
      }, result.codes)
    end
  )
end)

describe('結果テーブルの判別', function()
  -- no-op 実装 (ok/err が同じ空テーブルを返す) では失敗する正アサーションの組。
  it('ok と err は判別可能で識別子を運ぶ', function()
    local good = result.ok 'v'
    local bad = result.err('v', result.codes.E_REF)

    assert.is_true(good.ok)
    assert.is_false(bad.ok)
    assert.equals('review.Result', good.__class)
    assert.equals('review.Result', bad.__class)
    assert.equals('E_REF', bad.code)
  end)
end)
