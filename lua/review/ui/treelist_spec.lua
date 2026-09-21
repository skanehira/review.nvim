-- ui/treelist: file panel のツリーモデル (純ロジック)。docs/design/
-- features/diff-review.md「file panel」/ DESIGN.md「file panel 表示」が正本。
-- 検証対象は build が返す行テーブル (text / kind / path / spans)。バッファへの
-- 描画・カーソル・hl 適用は ui/filepanel_spec が持つ (ここは FS も窓も触らない)。
local treelist = require 'review.ui.treelist'

-- core/diff のパース結果 (File) の最小写し。viewed は filepanel 側で session から
-- 埋めて渡す (treelist は純粋な一覧組み立てのみ)。
local function f(path, status, added, deleted, viewed, comment)
  return {
    path = path,
    status = status,
    added = added,
    deleted = deleted,
    viewed = viewed == true,
    comment = comment == true,
  }
end

local function tree_opts(overrides)
  local opts = { mode = 'tree', base = 'main', head_display = 'working tree' }
  for k, v in pairs(overrides or {}) do
    opts[k] = v
  end
  return opts
end

local function texts(rows)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = r.text
  end
  return out
end

describe('treelist.build tree モード', function()
  it(
    'ヘッダ 2 行 + root ファイル行。viewed は indent 後・status 前の行頭 [✓]',
    function()
      local rows = treelist.build({
        f('a.lua', 'M', 2, 2, true),
        f('b.lua', 'A', 2, 1),
      }, tree_opts())
      assert.same({
        'Changes (2)',
        'Showing changes for: main..working tree',
        '[✓] M a.lua +2 -2',
        'A b.lua +2 -1',
      }, texts(rows))
      assert.equals('header', rows[1].kind)
      assert.is_nil(rows[1].path)
      assert.equals('file', rows[3].kind)
      assert.equals('a.lua', rows[3].path)
    end
  )

  it('縮退時は head 表示名が ref 名 (ヘッダ 2 行目が base..<ref>)', function()
    local rows = treelist.build({ f('a.lua', 'M', 1, 0) }, tree_opts { head_display = 'hotfix' })
    assert.equals('Showing changes for: main..hotfix', rows[2].text)
  end)

  it('単一 child dir 連鎖は連結表示し、末尾 / で dir を識別する', function()
    local rows = treelist.build({
      f('a.lua', 'M', 2, 2),
      f('src/deep/new.lua', 'A', 1, 0),
    }, tree_opts())
    assert.same({
      'Changes (2)',
      'Showing changes for: main..working tree',
      'A src/deep/',
      '    A new.lua +1 -0',
      'M a.lua +2 -2',
    }, texts(rows))
    assert.equals('dir', rows[3].kind)
    -- 連結後 deepest の dir path がキー (collapsed 集合と row_entry の同一語)
    assert.equals('src/deep', rows[3].path)
    assert.equals('src/deep/new.lua', rows[4].path)
  end)

  it('dir status は全 descendant の集約: 全同一はそのまま / 混在は *', function()
    local rows = treelist.build({
      f('lib/x.go', 'M', 1, 1),
      f('lib/y/r.go', 'A', 3, 0),
    }, tree_opts())
    -- lib の子は dir y と file x に分裂するので連結しない。混在 -> *
    assert.same({
      'Changes (2)',
      'Showing changes for: main..working tree',
      '* lib/',
      '  A y/',
      '    A r.go +3 -0',
      '  M x.go +1 -1',
    }, texts(rows))
    assert.equals('lib', rows[3].path)
    assert.equals('lib/y', rows[4].path)
  end)

  it('同一 dir 配下は dir 先行 -> file、各々名前昇順', function()
    local rows = treelist.build({
      f('README.md', 'M', 1, 1),
      f('docs/a.md', 'A', 1, 0),
      f('cmd/run.go', 'M', 1, 0),
      f('build.sh', 'A', 1, 0),
    }, tree_opts { base = 'main' })
    assert.same({
      'Changes (4)',
      'Showing changes for: main..working tree',
      'M cmd/',
      '  M run.go +1 -0',
      'A docs/',
      '  A a.md +1 -0',
      'M README.md +1 -1',
      'A build.sh +1 -0',
    }, texts(rows))
  end)

  it(
    '同名のファイルと dir が併存するときは末尾 / が区別 (cmd と cmd/)',
    function()
      local rows = treelist.build({
        f('cmd/main.go', 'A', 2, 0),
        f('cmd', 'M', 1, 0),
      }, tree_opts())
      assert.same({
        'Changes (2)',
        'Showing changes for: main..working tree',
        'A cmd/',
        '  A main.go +2 -0',
        'M cmd +1 -0',
      }, texts(rows))
      -- 行データは kind で区別できる (path は同じ語になりうる)
      assert.equals('dir', rows[3].kind)
      assert.equals('cmd', rows[3].path)
      assert.equals('file', rows[5].kind)
      assert.equals('cmd', rows[5].path)
    end
  )

  it(
    'collapsed の dir は行を残して子行 (dir ごと) を隠し、▸ を付ける',
    function()
      local rows = treelist.build({
        f('a.lua', 'M', 1, 0),
        f('src/deep/new.lua', 'A', 1, 0),
        f('src/top.lua', 'A', 1, 1),
      }, tree_opts { collapsed = { ['src/deep'] = true } })
      assert.same({
        'Changes (3)',
        'Showing changes for: main..working tree',
        'A src/',
        '  ▸ A deep/',
        '  A top.lua +1 -1',
        'M a.lua +1 -0',
      }, texts(rows))
      assert.equals('src/deep', rows[4].path)
    end
  )

  it('icon resolver 注入時は <status> <icon> <basename>。dir 行には付けない', function()
    local rows = treelist.build(
      {
        f('a.lua', 'M', 1, 0),
        f('b.md', 'M', 1, 0),
        f('src/n.lua', 'A', 1, 0),
      },
      tree_opts {
        icon = function(path)
          return path:match '%.lua$' and 'L' or nil
        end,
      }
    )
    assert.same({
      'Changes (3)',
      'Showing changes for: main..working tree',
      'A src/',
      '  A L n.lua +1 -0',
      'M L a.lua +1 -0',
      'M b.md +1 -0',
    }, texts(rows))
    -- icon はテキストに載るが hl span の外 (DEVICONS の hex 色は group 化しない決定)。
    -- spans は絶対 column (indent を含まない) なので位置で引く
    local a_file = rows[5]
    local name_span
    for _, s in ipairs(a_file.spans) do
      if s.group == 'ReviewPanelFile' then
        name_span = s
      end
    end
    assert.is_not_nil(name_span)
    assert.equals('a.lua', a_file.text:sub(name_span.from + 1, name_span.to))
    assert.equals('L ', a_file.text:sub(name_span.from - 1, name_span.from))
  end)

  it('絞り込み 0 件は行 0 (ヘッダも出さない)', function()
    assert.same({}, treelist.build({}, tree_opts()))
  end)

  it(
    'spans: status / dir 名 (ReviewPanelDir) / basename (ReviewPanelFile) / ± (Add・Remove)',
    function()
      local rows = treelist.build({
        f('src/deep/new.lua', 'A', 12, 3, true),
      }, tree_opts())
      -- 実テキストから span 範囲を引き直す (from/to が 1 バイトずれても検出できる形)
      local function pieces(row)
        local out = {}
        for _, s in ipairs(row.spans) do
          out[#out + 1] = { text = row.text:sub(s.from + 1, s.to), group = s.group }
        end
        return out
      end

      local dir = rows[3]
      assert.equals('A src/deep/', dir.text)
      assert.same({
        { text = 'A', group = 'ReviewPanelStatus' },
        { text = 'src/deep/', group = 'ReviewPanelDir' },
      }, pieces(dir))

      local file = rows[4]
      assert.equals('    [✓] A new.lua +12 -3', file.text)
      assert.same({
        { text = '[✓]', group = 'ReviewPanelStatus' },
        { text = 'A', group = 'ReviewPanelStatus' },
        { text = 'new.lua', group = 'ReviewPanelFile' },
        { text = '+12', group = 'ReviewPanelAdd' },
        { text = '-3', group = 'ReviewPanelRemove' },
      }, pieces(file))
    end
  )

  it(
    'コメントありファイルは status の後にコメントアイコン (無しは付かない。span は ReviewPanelComment)',
    function()
      local rows = treelist.build({
        f('a.lua', 'M', 1, 1, false, true),
        f('b.lua', 'A', 1, 0),
      }, tree_opts())
      assert.same({
        'Changes (2)',
        'Showing changes for: main..working tree',
        'M \u{EA6B} a.lua +1 -1',
        'A b.lua +1 -0',
      }, texts(rows))
      -- span はコメントアイコン (U+EA6B) のグリフ範囲 (後続 space は無 hl)
      local marks = {}
      for _, s in ipairs(rows[3].spans) do
        marks[#marks + 1] = { text = rows[3].text:sub(s.from + 1, s.to), group = s.group }
      end
      assert.same({
        { text = 'M', group = 'ReviewPanelStatus' },
        { text = '\u{EA6B}', group = 'ReviewPanelComment' },
        { text = 'a.lua', group = 'ReviewPanelFile' },
        { text = '+1', group = 'ReviewPanelAdd' },
        { text = '-1', group = 'ReviewPanelRemove' },
      }, marks)
    end
  )

  it(
    'ヘッダ行は span なし (filepanel がヘッダ band として grey 扱いしない)',
    function()
      local rows = treelist.build({ f('a.lua', 'M', 1, 0) }, tree_opts())
      assert.is_true(#rows[1].spans == 0)
    end
  )
end)

describe('treelist.build list モード', function()
  it(
    '従来フラット形式 (フルパス 1 行・パス昇順・行頭 [✓]) でヘッダなし',
    function()
      local rows = treelist.build({
        f('b.lua', 'M', 2, 1, true),
        f('src/deep/new.lua', 'A', 1, 0),
        f('a.lua', 'A', 5, 0),
      }, { mode = 'list' })
      assert.same({
        'A a.lua +5 -0',
        '[✓] M b.lua +2 -1',
        'A src/deep/new.lua +1 -0',
      }, texts(rows))
      assert.equals('file', rows[1].kind)
      assert.equals('a.lua', rows[1].path)
      assert.equals('src/deep/new.lua', rows[3].path)
    end
  )

  it('list モードでも spans は同じグループ規約', function()
    local rows = treelist.build({ f('a.lua', 'M', 1, 0, true) }, { mode = 'list' })
    local groups = {}
    for _, s in ipairs(rows[1].spans) do
      groups[s.group] = true
    end
    assert.is_true(groups.ReviewPanelFile == true)
    assert.is_true(groups.ReviewPanelStatus == true)
    assert.is_true(groups.ReviewPanelAdd == true)
    assert.is_true(groups.ReviewPanelRemove == true)
  end)

  it('list モードでもコメント icon は付く (フルパス行の status 後)', function()
    local rows = treelist.build({ f('src/a.lua', 'M', 1, 1, false, true) }, { mode = 'list' })
    assert.same({ 'M \u{EA6B} src/a.lua +1 -1' }, texts(rows))
  end)

  it('collapsed/mode 省略時は tree が既定 (既定がフォルダツリー)', function()
    local rows = treelist.build({ f('src/deep/new.lua', 'A', 1, 0) }, nil)
    assert.equals('Changes (1)', rows[1].text)
    assert.equals('dir', rows[3] and rows[3].kind or 'none')
  end)
end)
