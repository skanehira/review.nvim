-- core/comment: コメントモデル (DESIGN.md「データスキーマ」Comment 定義)。
-- 追加・編集・削除・カーソル行検索・id 採番 (max+1)・range 正規化の純粋ロジック。
-- comments は session JSON の comments 配列そのもの (in-place 操作)。
-- created_at は DI 前提 (時刻を取らない = 決定的テスト)。
local comment = require 'review.core.comment'

local function existing(id, file, line, end_line)
  return {
    id = id,
    file = file,
    line = line,
    end_line = end_line,
    body = 'body-' .. id,
    state = 'active',
    created_at = 100,
  }
end

describe('comment.new_id', function()
  it('空リストでは最初の id として c1 を採る', function()
    assert.equals('c1', comment.new_id {})
  end)

  it('既存 id の数値 max+1 を返す (文字列順ではない)', function()
    local comments = {
      existing('c2', 'a.lua', 1, 1),
      existing('c10', 'a.lua', 2, 2),
      existing('c9', 'a.lua', 3, 3),
    }
    assert.equals('c11', comment.new_id(comments))
  end)

  it('削除で飛んだ id があっても max+1 (c3 削除済みで c1,c5 なら c6)', function()
    local comments = {
      existing('c1', 'a.lua', 1, 1),
      existing('c5', 'a.lua', 2, 2),
    }
    assert.equals('c6', comment.new_id(comments))
  end)
end)

describe('comment.normalize_range', function()
  it('end_line 省略は単一行として line と同値にする', function()
    local line, end_line = comment.normalize_range(7)
    assert.same({ 7, 7 }, { line, end_line })
  end)

  it(
    'visual 逆方向選択で end_line < line なら入れ替えて line <= end_line にする',
    function()
      local line, end_line = comment.normalize_range(10, 8)
      assert.same({ 8, 10 }, { line, end_line })
    end
  )

  it('正規 range (5, 5) はそのまま返す', function()
    local line, end_line = comment.normalize_range(5, 5)
    assert.same({ 5, 5 }, { line, end_line })
  end)
end)

describe('comment.add', function()
  it(
    'attr から id 採番・state=active・end_line 補完を済んだ Comment を返す',
    function()
      local comments = {}
      local added = comment.add(comments, {
        file = 'lib.lua',
        line = 3,
        end_line = 5,
        body = 'これは\nマルチライン',
        anchor = { before = 'l2', line = 'l3', after = 'l4' },
        created_at = 1234,
      })

      assert.same({
        id = 'c1',
        file = 'lib.lua',
        line = 3,
        end_line = 5,
        body = 'これは\nマルチライン',
        anchor = { before = 'l2', line = 'l3', after = 'l4' },
        state = 'active',
        created_at = 1234,
      }, added)
      assert.same({ added }, comments)
    end
  )

  it('end_line 逆転入力は正規化してから保存する', function()
    local comments = {}
    local added = comment.add(comments, {
      file = 'lib.lua',
      line = 10,
      end_line = 8,
      body = 'range',
      created_at = 1,
    })

    assert.same({
      id = 'c1',
      file = 'lib.lua',
      line = 8,
      end_line = 10,
      body = 'range',
      state = 'active',
      created_at = 1,
    }, added)
  end)

  it('末尾へ追加を続けると c1 に続き c2 が採番される', function()
    local comments = {}
    comment.add(comments, { file = 'a.lua', line = 1, body = 'first', created_at = 1 })
    local second =
      comment.add(comments, { file = 'b.lua', line = 2, body = 'second', created_at = 2 })

    assert.equals('c2', second.id)
    assert.equals('c1', comments[1].id)
    assert.equals(2, #comments)
  end)

  it('既存 c4 があるリストでは次の add は c5 (max+1 連続)', function()
    local comments = { existing('c4', 'a.lua', 1, 1) }
    local added = comment.add(comments, {
      file = 'a.lua',
      line = 2,
      body = 'next',
      created_at = 5,
    })
    assert.equals('c5', added.id)
  end)

  it('anchor 未指定のコメントには anchor キーを持たせない', function()
    local comments = {}
    local added = comment.add(comments, { file = 'a.lua', line = 1, body = 'x', created_at = 1 })

    assert.same({
      id = 'c1',
      file = 'a.lua',
      line = 1,
      end_line = 1,
      body = 'x',
      state = 'active',
      created_at = 1,
    }, added)
    assert.is_nil(added.anchor)
  end)
end)

describe('comment.update', function()
  it('id で探して body を書き換え、更新後のコメントを返す', function()
    local comments = { existing('c1', 'a.lua', 4, 4), existing('c2', 'b.lua', 9, 12) }
    local updated = comment.update(comments, 'c2', '書き換え後')

    assert.same({
      id = 'c2',
      file = 'b.lua',
      line = 9,
      end_line = 12,
      body = '書き換え後',
      state = 'active',
      created_at = 100,
    }, updated)
    assert.equals('書き換え後', comments[2].body)
  end)

  it('存在しない id は nil を返し、リストは無変更', function()
    local comments = { existing('c1', 'a.lua', 4, 4) }
    local result = comment.update(comments, 'c99', 'noop')

    assert.is_nil(result)
    assert.same({ existing('c1', 'a.lua', 4, 4) }, comments)
  end)
end)

describe('comment.remove', function()
  it(
    'id で探して削除し、削除されたコメントを返して配列を詰める',
    function()
      local comments = {
        existing('c1', 'a.lua', 1, 1),
        existing('c2', 'a.lua', 2, 2),
        existing('c3', 'a.lua', 3, 3),
      }
      local removed = comment.remove(comments, 'c2')

      assert.same(existing('c2', 'a.lua', 2, 2), removed)
      assert.same({ existing('c1', 'a.lua', 1, 1), existing('c3', 'a.lua', 3, 3) }, comments)
    end
  )

  it('存在しない id は nil を返し、リストは無変更', function()
    local comments = { existing('c1', 'a.lua', 1, 1) }
    local removed = comment.remove(comments, 'c99')

    assert.is_nil(removed)
    assert.same({ existing('c1', 'a.lua', 1, 1) }, comments)
  end)
end)

describe('comment.find_at', function()
  it(
    'カーソル行を range に含む全コメントを file 限定で列挙する (複数該当可)',
    function()
      local comments = {
        existing('c1', 'a.lua', 4, 6),
        existing('c2', 'a.lua', 5, 5),
        existing('c3', 'other.lua', 5, 5),
        existing('c4', 'a.lua', 1, 2),
      }

      assert.same(
        { existing('c1', 'a.lua', 4, 6), existing('c2', 'a.lua', 5, 5) },
        comment.find_at(comments, 'a.lua', 5)
      )
    end
  )

  it('range 境界行 (先頭 / 末尾) は該当、外側 (end_line+1) は非該当', function()
    local single = { existing('c1', 'a.lua', 8, 10) }

    assert.same({ existing('c1', 'a.lua', 8, 10) }, comment.find_at(single, 'a.lua', 8))
    assert.same({ existing('c1', 'a.lua', 8, 10) }, comment.find_at(single, 'a.lua', 10))
    assert.same({}, comment.find_at(single, 'a.lua', 11))
    assert.same({}, comment.find_at(single, 'a.lua', 7))
  end)
end)
