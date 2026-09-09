-- core/prompt: プロンプト文字列組み立ての純粋関数 (docs/design/features/ai-prompt.md
-- 「入出力と振る舞い」)。見出し定型文は docs のサンプルから一字一句正本 (issue #7 DoD)。
local prompt = require 'review.core.prompt'

local BRANCH_CTX = { mode = 'branch', base = 'main', head = 'feature' }
local PR_CTX = {
  mode = 'pr',
  base = 'main',
  head = 'review-nvim/pr-42',
  pr = { number = 42, url = 'https://github.com/skanehira/demo/pull/42' },
  worktree_path = '/xdg/review.nvim/worktrees/pr-42',
}
local WORKTREE_CTX = {
  mode = 'branch',
  base = 'main',
  head = 'feature',
  worktree_path = '/xdg/review.nvim/worktrees/main--feature',
}

local function comment(id, file, line, end_line, body, state)
  return {
    id = id,
    file = file,
    line = line,
    end_line = end_line or line,
    body = body,
    anchor = vim.NIL,
    state = state or 'active',
    created_at = 1,
  }
end

describe('core.prompt.header 見出し定型文', function()
  it('branch は Review the changes in <base>..<head>. (docs サンプル正本)', function()
    assert.equals(
      'Review the changes in main..feature. Please address the comments below.',
      prompt.header(BRANCH_CTX)
    )
  end)

  it('pr は Review PR #<n> (<url>) — <base>..<head>. (docs 書式正本)', function()
    assert.equals(
      'Review PR #42 (https://github.com/skanehira/demo/pull/42) — '
        .. 'main..review-nvim/pr-42. Please address the comments below.',
      prompt.header(PR_CTX)
    )
  end)
end)

describe('core.prompt.ref @path + 行アンカー', function()
  it('1 行 range は #L<行> (new 側行番号)', function()
    assert.equals(
      '@lua/review/init.lua#L10',
      prompt.ref(comment('c1', 'lua/review/init.lua', 10, nil, 'b'), BRANCH_CTX)
    )
  end)

  it('複数行 range は #L<始>-L<終>', function()
    assert.equals(
      '@lua/review/diff.lua#L42-L48',
      prompt.ref(comment('c1', 'lua/review/diff.lua', 42, 48, 'b'), BRANCH_CTX)
    )
  end)

  it('worktree あり ctx では worktree 基準の絶対 path になる', function()
    assert.equals('@a.lua#L42', prompt.ref(comment('c1', 'a.lua', 42, nil, 'b'), BRANCH_CTX))
    assert.equals(
      '@/xdg/review.nvim/worktrees/main--feature/a.lua#L42',
      prompt.ref(comment('c1', 'a.lua', 42, nil, 'b'), WORKTREE_CTX)
    )
  end)
end)

describe('core.prompt.filter_active outdated 既定除外と id 昇順', function()
  it('outdated を除外し除外件数を返す (active は残る)', function()
    local c1 = comment('c1', 'a.lua', 1, nil, 'keep')
    local c2 = comment('c2', 'a.lua', 2, nil, 'stale', 'outdated')
    local active, excluded = prompt.filter_active { c1, c2 }
    assert.same({ c1 }, active)
    assert.equals(1, excluded)
  end)

  it('並びは id の数値昇順 (作成順。辞書順で c10 < c2 になる不做)', function()
    local c1 = comment('c1', 'a.lua', 1, nil, 'a')
    local c2 = comment('c2', 'a.lua', 2, nil, 'b')
    local c10 = comment('c10', 'a.lua', 3, nil, 'c')
    local active, excluded = prompt.filter_active { c10, c2, c1 }
    assert.same({ c1, c2, c10 }, active)
    assert.equals(0, excluded)
  end)
end)

describe('core.prompt.build / body 全文組み立て', function()
  it(
    'build: docs サンプルと全文一致 (見出し + 複数行 range + 1 行アンカー)',
    function()
      local comments = {
        comment(
          'c1',
          'lua/review/diff.lua',
          42,
          48,
          'この関数は行番号計算を重複実装している。core/diff に寄せて削除してよい'
        ),
        comment(
          'c2',
          'lua/review/init.lua',
          10,
          nil,
          'setup 側で config を deep merge したい'
        ),
      }
      assert.equals(
        table.concat({
          'Review the changes in main..feature. Please address the comments below.',
          '',
          '@lua/review/diff.lua#L42-L48',
          'この関数は行番号計算を重複実装している。core/diff に寄せて削除してよい',
          '',
          '@lua/review/init.lua#L10',
          'setup 側で config を deep merge したい',
        }, '\n'),
        prompt.build(comments, BRANCH_CTX)
      )
    end
  )

  it(
    'build: PR + worktree では PR 見出しと worktree 絶対 path の全文になる',
    function()
      assert.equals(
        table.concat({
          'Review PR #42 (https://github.com/skanehira/demo/pull/42) — '
            .. 'main..review-nvim/pr-42. Please address the comments below.',
          '',
          '@/xdg/review.nvim/worktrees/pr-42/demo.lua#L7',
          'check error handling',
        }, '\n'),
        prompt.build({ comment('c1', 'demo.lua', 7, nil, 'check error handling') }, PR_CTX)
      )
    end
  )

  it(
    'build: 複数行 body は見出し行の後の続き行としてそのまま置かれる',
    function()
      assert.equals(
        table.concat({
          'Review the changes in main..feature. Please address the comments below.',
          '',
          '@a.lua#L5-L6',
          'first line',
          'second line',
        }, '\n'),
        prompt.build({ comment('c1', 'a.lua', 5, 6, 'first line\nsecond line') }, BRANCH_CTX)
      )
    end
  )

  it('build: body 内の @ は加工しない (エージェント側解釈に任せる)', function()
    assert.equals(
      table.concat({
        'Review the changes in main..feature. Please address the comments below.',
        '',
        '@a.lua#L1',
        'mention @other.lua instead',
      }, '\n'),
      prompt.build({ comment('c1', 'a.lua', 1, nil, 'mention @other.lua instead') }, BRANCH_CTX)
    )
  end)

  it('build: outdated 混在時は active のみで構築される', function()
    assert.equals(
      table.concat({
        'Review the changes in main..feature. Please address the comments below.',
        '',
        '@a.lua#L1',
        'keep',
        '',
        '@a.lua#L3',
        'keep too',
      }, '\n'),
      prompt.build({
        comment('c1', 'a.lua', 1, nil, 'keep'),
        comment('c2', 'a.lua', 2, nil, 'stale', 'outdated'),
        comment('c3', 'a.lua', 3, nil, 'keep too'),
      }, BRANCH_CTX)
    )
  end)

  it('body: 見出しなし (y キー用の本文のみブロック連結)', function()
    assert.equals(
      table.concat({ '@a.lua#L2-L3', 'use map' }, '\n'),
      prompt.body({ comment('c1', 'a.lua', 2, 3, 'use map') }, BRANCH_CTX)
    )
  end)
end)
