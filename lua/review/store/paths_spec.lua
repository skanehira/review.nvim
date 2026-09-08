-- slug / repo-hash / パス配置の検証 (docs/design/features/persistence-restore.md
-- 「実装の配置」、DESIGN.md「データスキーマ」「永続化」)。
-- 期待値は shasum 実測値などのリテラルで書き、実装の再帰呼び出しで組み立てない
-- (トートロジー回避)。
local paths = require 'review.store.paths'

describe('slug 生成', function()
  it('branch slug は refs 組を -- で連結する (main..feature → main--feature)', function()
    assert.equals('main--feature', paths.branch_slug('main', 'feature'))
  end)

  it(
    'slug に使えない文字 ([A-Za-z0-9._-] 以外) は 1 文字ずつ _ に置換される',
    function()
      assert.equals(
        'refs_heads_main--feature_two',
        paths.branch_slug('refs/heads/main', 'feature/two')
      )
      assert.equals('a_b--c_d', paths.branch_slug('a b', 'c!d'))
    end
  )

  it('slug に使える文字 . _ - はそのまま残る', function()
    assert.equals('v1.2.0--fix_3-x', paths.branch_slug('v1.2.0', 'fix_3-x'))
  end)

  it(
    'PR slug は pr-<number> (branch slug とは -- を含まない形で衝突しない)',
    function()
      assert.equals('pr-42', paths.pr_slug(42))
      assert.equals('pr-7', paths.pr_slug '7')
    end
  )

  it(
    'ref 名由来の衝突は生成規則上あり得る (a-- + b と a + --b が同一 slug)',
    function()
      -- この衝突自体は検出し、新規作成を拒否して既存を案内する (persistence-restore.md
      -- 「エッジケースの決定」)。拒否の判断材料が slug_conflict。
      assert.equals('a----b', paths.branch_slug('a--', 'b'))
      assert.equals('a----b', paths.branch_slug('a', '--b'))
    end
  )
end)

describe('slug 衝突検出', function()
  it('既存セッションが無し (ファイル不在) は衝突ではない', function()
    assert.equals(false, paths.slug_conflict(nil, 'main', 'feature'))
  end)

  it(
    '既存セッションの refs 組と一致する新規開始は衝突ではない (継承)',
    function()
      assert.equals(
        false,
        paths.slug_conflict({ base = 'main', head = 'feature' }, 'main', 'feature')
      )
    end
  )

  it('同一 slug に異なる refs 組が既存なら衝突', function()
    assert.equals(true, paths.slug_conflict({ base = 'a--', head = 'b' }, 'a', '--b'))
  end)

  it(
    'refs 組は 1 項目だけでも違えば衝突 (base / head 項の独立性と or を pin)',
    function()
      -- 既存 { main, feature } に対し 1 項目だけ違う入力。両方違いの true ケースだけでは
      -- 比較項を 1 つ落とす変異 (head 項削除なら base 一致・head 違いを見逃す) も
      -- or を and にする変異も切り分けられないため、1 項目違いを 2 方向揃えて
      -- 契約「既存の refs 組と 1 つでも違えば衝突」を pin する
      -- (persistence-restore.md「エッジケースの決定」)。
      local existing = { base = 'main', head = 'feature' }
      local cases = {
        { base = 'main', head = 'other' }, -- base 一致・head 違い
        { base = 'other', head = 'feature' }, -- base 違い・head 一致
      }
      local actual = {}
      for i, refs in ipairs(cases) do
        actual[i] = paths.slug_conflict(existing, refs.base, refs.head)
      end
      assert.same({ true, true }, actual)
    end
  )
end)

describe('repo-hash 生成', function()
  -- ベクトルは shasum 実測値 (RFC 3174 既知ベクトルと参考値が一致することも確認済み)。
  it('sha1_hex は既知ベクトルと一致する (空文字・abc・43 文字)', function()
    assert.equals('da39a3ee5e6b4b0d3255bfef95601890afd80709', paths.sha1_hex '')
    assert.equals('a9993e364706816aba3e25717850c26c9cd0d89d', paths.sha1_hex 'abc')
    assert.equals(
      '2fd4e1c67a2d28fced849ee1bb76e7391b93eb12',
      paths.sha1_hex 'The quick brown fox jumps over the lazy dog'
    )
  end)

  it(
    'sha1_hex は複数ブロックと埋め境界で参照実装と一致する (ml=55/56/63/64/100)',
    function()
      -- repo パスは 63 バイトを超えると複数ブロックになる。pad 分岐を跨ぐ
      -- 境界長を python hashlib / shasum 両者で照合した実測値で固定する
      -- (paths.lua 実装済みからの回帰ベクトル = シナリオ補完)。
      assert.equals('5a8c825e7bddd45f0936f3a6c4a34760a190e60c', paths.sha1_hex(string.rep('z', 55)))
      assert.equals('6558fd1a7f42fe09fa506e63d70c57e3ed5e7b62', paths.sha1_hex(string.rep('w', 56)))
      assert.equals('b31b2f10be0371619d8c3648db7d37e72c5c6a53', paths.sha1_hex(string.rep('y', 63)))
      assert.equals('bb2fa3ee7afb9f54c6dfb5d021f14b1ffe40c163', paths.sha1_hex(string.rep('x', 64)))
      assert.equals(
        '7574cdf5cf8c5cee363d016fbe08d980aed6ccc9',
        paths.sha1_hex(string.rep('a', 30) .. string.rep('b', 30) .. string.rep('c', 40))
      )
    end
  )

  it(
    'repo_hash は sha1(repo) の先頭 16 桁で、同じ入力に対して決定性を持つ',
    function()
      assert.equals('f90cc21f45278cc2', paths.repo_hash '/repo-x')
      assert.equals(paths.repo_hash '/repo-x', paths.repo_hash '/repo-x')
    end
  )

  it('repo_hash は異なる repo を異なる値に区別する', function()
    assert.equals('f90cc21f45278cc2', paths.repo_hash '/repo-x')
    assert.equals('dfcd58d3c11bac7d', paths.repo_hash '/repo-y')
  end)
end)

describe('セッションパス配置', function()
  after_each(function()
    paths._set_data_dir(nil)
  end)

  it('sessions_dir は注入した data dir 直下の review.nvim/sessions', function()
    paths._set_data_dir '/data'
    assert.equals('/data/review.nvim/sessions', paths.sessions_dir())
  end)

  it('repo_dir は sessions_dir/<repo-hash> (sha1 先頭 16 桁)', function()
    paths._set_data_dir '/data'
    assert.equals('/data/review.nvim/sessions/f90cc21f45278cc2', paths.repo_dir '/repo-x')
  end)

  it('session_file は <data>/review.nvim/sessions/<repo-hash>/<slug>.json', function()
    paths._set_data_dir '/data'
    assert.equals(
      '/data/review.nvim/sessions/f90cc21f45278cc2/main--feature.json',
      paths.session_file('/repo-x', 'main--feature')
    )
  end)

  it('corrupt_file は session_file に .corrupt を接尾した退避先', function()
    paths._set_data_dir '/data'
    assert.equals(
      '/data/review.nvim/sessions/f90cc21f45278cc2/main--feature.json.corrupt',
      paths.corrupt_file('/repo-x', 'main--feature')
    )
  end)
end)
