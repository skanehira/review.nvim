-- ui/syntaxhl: basename に内蔵 syntax を走らせて highlight span を返す
-- (filepanel のファイル名色差し。docs/design/features/diff-review.md「file panel」)。
-- 機構: 共有の off-screen 最小窓で buffer に filetype を当て、synID が返す group を
-- 連runs に畳む。対応 syntax が無い filetype / syntax 無効環境は nil (呼び出し側の
-- 現状色 ReviewPanelFile にフォールバック)。
local syntaxhl = require 'review.ui.syntaxhl'

local function use_syntax()
  before_each(function()
    vim.cmd 'syntax enable'
    syntaxhl.reset()
  end)
  after_each(function()
    syntaxhl.reset()
  end)
end

describe('syntaxhl.spans', function()
  use_syntax()

  it(
    'lua syntax の keyword を含む basename は該当 col 区間の group を返す (for.lua -> 冒頭 luaRepeat)',
    function()
      local spans = syntaxhl.spans 'for.lua'
      assert.is_true(spans ~= nil, 'lua syntax が解けなかった')
      local first = spans[1]
      assert.equals(0, first.from)
      assert.equals(3, first.to, 'for (3 byte) を覆う span でない: ' .. vim.inspect(spans))
      assert.equals('luaRepeat', first.group)
    end
  )

  it('syntax に対応の無い filetype は nil (呼び出し側フォールバック)', function()
    assert.is_nil(syntaxhl.spans 'weird.zzzznotalang')
  end)

  it('空 / 不正入力は nil で窓を作らない', function()
    assert.is_nil(syntaxhl.spans(nil))
    assert.is_nil(syntaxhl.spans '')
  end)

  it(
    '同一 name の 2 回目の呼出は cache hit で同じ結果 (窓の張替えは行われない)',
    function()
      local a = syntaxhl.spans 'for.lua'
      local b = syntaxhl.spans 'for.lua'
      assert.same(a, b)
    end
  )

  it('reset 後は遅延再開で見かけが変わらない (singleton 再生成)', function()
    local a = syntaxhl.spans 'for.lua'
    syntaxhl.reset()
    local b = syntaxhl.spans 'for.lua'
    assert.same(a, b)
  end)

  -- 検出自習 (リトマス B): span を常に nil にする resolver では最初の test が
  -- 落ちること。group を 1 文字ずらすと luaRepeat test が落ちる (assert 対象は
  -- from/to/group の三者)。
end)
