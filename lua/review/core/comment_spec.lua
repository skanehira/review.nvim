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

describe('comment.remove_all', function()
  it('comments を空にして削除件数を返す (in-place。参照は据え置き)', function()
    local comments = {
      existing('c1', 'a.lua', 1, 1),
      existing('c2', 'a.lua', 2, 2),
      existing('c3', 'a.lua', 3, 3),
    }
    local removed = comment.remove_all(comments)

    assert.equals(3, removed)
    assert.same({}, comments)
  end)

  it('空リストでは 0 を返す', function()
    local comments = {}
    assert.equals(0, comment.remove_all(comments))
    assert.same({}, comments)
  end)

  it('outdated 状態のコメントも無条件で全件消える', function()
    local stale = existing('c1', 'a.lua', 1, 1)
    stale.state = 'outdated'
    local comments = { stale, existing('c2', 'a.lua', 2, 2) }

    assert.equals(2, comment.remove_all(comments))
    assert.same({}, comments)
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

describe('comment.add (GitHub 連携フィールド)', function()
  it('subject_type=file は line/end_line を持たないコメントを作る', function()
    local comments = {}
    local added = comment.add(comments, {
      file = 'lib.lua',
      subject_type = 'file',
      body = 'file-level note',
      created_at = 5,
    })
    assert.same({
      id = 'c1',
      file = 'lib.lua',
      subject_type = 'file',
      body = 'file-level note',
      state = 'active',
      created_at = 5,
    }, added)
    assert.is_nil(added.line)
    assert.is_nil(added.end_line)
  end)

  it(
    '指定時のみ origin / gh_id / in_reply_to 等を載せる (旧スキーマ互換)',
    function()
      local comments = {}
      local plain = comment.add(comments, { file = 'a.lua', line = 1, body = 'x', created_at = 1 })
      assert.is_nil(plain.origin)
      assert.is_nil(plain.gh_id)

      local gh = comment.add(comments, {
        file = 'a.lua',
        line = 2,
        body = 'reply',
        created_at = 2,
        origin = 'local',
        gh_id = nil,
        in_reply_to = 'c1',
      })
      assert.equals('local', gh.origin)
      assert.equals('c1', gh.in_reply_to)
      assert.is_nil(gh.gh_id) -- 明示 nil は載せない
    end
  )
end)

describe('comment.is_file_level / thread_at / file_thread', function()
  local file_c = function(id, line, end_line)
    return { id = id, file = 'a.lua', line = line, end_line = end_line, state = 'active' }
  end

  it('subject_type=file を is_file_level が判定する', function()
    assert.is_false(comment.is_file_level(file_c('c1', 1, 1)))
    local fc = file_c('c2', 1, 1)
    fc.subject_type = 'file'
    assert.is_true(comment.is_file_level(fc))
  end)

  it(
    'display_label: gh は作者 login / local は id / pending は ⚠ (スレッド箱と i view 共通)',
    function()
      assert.equals('octocat', comment.display_label { origin = 'gh', gh_user = 'octocat' })
      assert.equals('gh', comment.display_label { origin = 'gh', gh_user = nil })
      -- push 済み local は自身の login
      assert.equals(
        'skanehira',
        comment.display_label { origin = 'local', gh_user = 'skanehira', gh_id = 1 }
      )
      -- branch のローカルは id
      assert.equals('c3', comment.display_label { id = 'c3', origin = 'local' })
      -- pending (未 submit / 未 push) は ⚠
      assert.equals(
        'octocat \u{26A0}',
        comment.display_label({ origin = 'gh', gh_user = 'octocat', gh_state = 'pending' }, true)
      )
    end
  )

  it(
    'thread_at は表示 anchor (range 最終行) を共有するコメント群を返す',
    function()
      local comments = {
        file_c('c1', 4, 6),
        file_c('c2', 6, 6),
        file_c('c3', 5, 5),
        file_c('c4', 9, 9),
      }
      assert.same({ comments[1], comments[2] }, comment.thread_at(comments, 'a.lua', 6))
      assert.same({ comments[3] }, comment.thread_at(comments, 'a.lua', 5))
      assert.same({}, comment.thread_at(comments, 'a.lua', 10))
    end
  )

  it('thread_at はファイルレベルを対象外にし、file_thread が返す', function()
    local fc = file_c('c1', 1, 1)
    fc.subject_type = 'file'
    local comments = { file_c('c2', 5, 5), fc }
    assert.same({ fc }, comment.file_thread(comments, 'a.lua'))
    assert.same({}, comment.thread_at(comments, 'a.lua', 1))
    assert.same({}, comment.file_thread(comments, 'b.lua'))
  end)
end)

describe('comment.reply_target', function()
  local mk = function(id, opts)
    local c = {
      id = id,
      file = opts.file or 'a.lua',
      line = opts.line,
      end_line = opts.end_line or opts.line,
      state = 'active',
    }
    for _, k in ipairs { 'origin', 'gh_id', 'in_reply_to', 'subject_type' } do
      if opts[k] ~= nil then
        c[k] = opts[k]
      end
    end
    return c
  end

  it('gh の根コメント (in_reply_to=nil) の gh_id を返す (行スレッド)', function()
    local comments = {
      mk('c1', { origin = 'gh', gh_id = 101, line = 5, in_reply_to = nil }),
      mk('c2', { origin = 'gh', gh_id = 102, line = 5, in_reply_to = 101 }),
    }
    assert.equals(101, comment.reply_target(comments, 'a.lua', 5))
  end)

  it('gh 根が無いローカルスレッドは根コメント id を返す', function()
    local comments = {
      mk('c1', { line = 5, in_reply_to = nil }),
      mk('c2', { line = 5, in_reply_to = 'c1' }),
    }
    assert.equals('c1', comment.reply_target(comments, 'a.lua', 5))
  end)

  it('push 済みローカル根 (gh_id あり) はその gh_id を返す', function()
    local comments = {
      mk('c1', { line = 5, in_reply_to = nil, gh_id = 201 }),
    }
    assert.equals(201, comment.reply_target(comments, 'a.lua', 5))
  end)

  it('スレッドが無い行は nil を返す', function()
    local comments = { mk('c1', { line = 5 }) }
    -- 対照: スレッドのある行は根を返す (常に nil を返す実装をここで落とす)
    assert.equals('c1', comment.reply_target(comments, 'a.lua', 5))
    assert.is_nil(comment.reply_target(comments, 'a.lua', 6))
    assert.is_nil(comment.reply_target(comments, 'b.lua', 5))
    assert.is_nil(comment.reply_target({}, 'a.lua', 5))
  end)

  it('ファイルレベルスレッド (line=nil) の根を返す', function()
    local comments = {
      mk('c1', { subject_type = 'file', origin = 'gh', gh_id = 301, in_reply_to = nil }),
      mk('c2', { subject_type = 'file', origin = 'gh', gh_id = 302, in_reply_to = 301 }),
    }
    assert.equals(301, comment.reply_target(comments, 'a.lua', nil))
  end)
end)

describe('comment.from_gh', function()
  it('GitHub の review comment オブジェクトを Comment に正規化する', function()
    local gh = {
      id = 500,
      path = 'src/a.lua',
      body = 'use table.insert',
      line = 12,
      in_reply_to_id = nil,
      user = { login = 'octocat' },
      created_at = '2024-01-02T03:04:05Z',
      subject_type = 'line',
    }
    local c = comment.from_gh(gh, { id = 'c7' })
    assert.same({
      id = 'c7',
      file = 'src/a.lua',
      body = 'use table.insert',
      origin = 'gh',
      gh_id = 500,
      gh_user = 'octocat',
      in_reply_to = nil,
      created_at = 1704164645, -- 2024-01-02T03:04:05Z の UTC epoch (TZ 非依存)
      state = 'active',
      line = 12,
      end_line = 12,
    }, c)
  end)

  it('subject_type=file は line を持たない', function()
    local gh = {
      id = 501,
      path = 'src/a.lua',
      body = 'note on the file',
      line = nil,
      user = { login = 'octocat' },
      created_at = 'bad-date',
      subject_type = 'file',
    }
    local c = comment.from_gh(gh, { id = 'c8' })
    assert.equals('file', c.subject_type)
    assert.is_nil(c.line)
    assert.equals(0, c.created_at)
  end)

  it('line が無いコメントは original_line を仮置きする (outdated 予備)', function()
    local gh = {
      id = 502,
      path = 'a.lua',
      body = 'stale',
      line = nil,
      original_line = 3,
      user = { login = 'x' },
      created_at = '2024-01-02T03:04:05Z',
      subject_type = 'line',
    }
    local c = comment.from_gh(gh, { id = 'c9' })
    assert.equals(3, c.line)
    assert.equals(3, c.end_line)
  end)

  it('line が vim.NIL (JSON null) でも line として扱わない', function()
    -- vim.json.decode は JSON の null を vim.NIL (userdata) にするため
    -- `~= nil` で拾えない。`comment.line > count` が userdata 比較で落ちる
    -- (pr_comments の display_state) 事故の根絶をここで pin する。
    local gh = {
      id = 503,
      path = 'a.lua',
      body = 'null line',
      line = vim.NIL,
      original_line = vim.NIL,
      user = { login = 'x' },
      created_at = '2024-01-02T03:04:05Z',
      subject_type = 'line',
    }
    local c = comment.from_gh(gh, { id = 'c10' })
    -- line / end_line キーを持たないことを全体比較で pin する
    assert.same({
      id = 'c10',
      file = 'a.lua',
      body = 'null line',
      origin = 'gh',
      gh_id = 503,
      gh_user = 'x',
      created_at = 1704164645,
      state = 'active',
    }, c)
  end)

  it('line が vim.NIL でも original_line があればそれを仮置きする', function()
    local gh = {
      id = 504,
      path = 'a.lua',
      body = 'null line with original',
      line = vim.NIL,
      original_line = 4,
      user = { login = 'x' },
      created_at = '2024-01-02T03:04:05Z',
      subject_type = 'line',
    }
    local c = comment.from_gh(gh, { id = 'c11' })
    assert.equals(4, c.line)
    assert.equals(4, c.end_line)
  end)
end)
