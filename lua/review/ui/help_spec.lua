-- ui/help: <F1> help float (diff-review.md「操作」)。キー一覧の表示と
-- <Esc>/q で閉じることを、実キーシーケンス (:normal 駆動) で検証する。
-- 表示行は `<key> <説明>` の 1 行フォーマット (詳細は help.lua)。
local config = require 'review.config'
local help = require 'review.ui.help'

local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)

local state = {}

-- plenary busted は describe 外のフックを持たない (init_spec.lua と同じ helper 方式)。
local function use_isolated_tabpage()
  before_each(function()
    config.reset()
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
  end)
end

local function tab_wins()
  return #vim.api.nvim_tabpage_list_wins(state.tab)
end

local function has_line(lines, expected)
  for _, line in ipairs(lines) do
    if line == expected then
      return true
    end
  end
  return false
end

describe('help.open', function()
  use_isolated_tabpage()
  it('help float が開き、既定キーバインドの行が揃う (markdown)', function()
    help.open()
    assert.equals(2, tab_wins())
    assert.equals('markdown', vim.bo[0].filetype)
    assert.equals(3, vim.wo.conceallevel)
    assert.equals('n', vim.wo.concealcursor)
    assert.is_true(vim.wo.wrap)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_true(has_line(lines, '# review.nvim キーバインド'))
    assert.is_true(has_line(lines, '## レビュー窓 (head / base)'))
    assert.is_true(has_line(lines, '## file panel (変更ファイル一覧)'))
    assert.is_true(
      has_line(lines, '- **c** 作成コメント (visual-line で範囲指定・head 窓のみ)')
    )
    assert.is_true(
      has_line(lines, '- **e** カーソル行のコメントを編集 (head 窓のみ)')
    )
    assert.is_true(
      has_line(
        lines,
        '- **d** カーソル行のコメントを削除 (arming: 同じ行でもう一度 d)'
      )
    )
    assert.is_true(
      has_line(lines, '- **y** カーソル行のコメントのプロンプトを yank')
    )
    assert.is_true(has_line(lines, '- **<Tab>** 次のファイルへ (端では無動作)'))
    assert.is_true(has_line(lines, '- **<S-Tab>** 前のファイルへ (端では無動作)'))
    assert.is_true(has_line(lines, '- **[F** 最初のファイルへ'))
    assert.is_true(has_line(lines, '- **]F** 最後のファイルへ'))
    assert.is_true(has_line(lines, '- **R** 差分を再取得 (リフレッシュ)'))
    assert.is_true(has_line(lines, '- **<F1>** このヘルプ (g? でも開く)'))
    assert.is_true(
      has_line(lines, '- **<leader>e** file panel (変更ファイル一覧) へ移動')
    )
    assert.is_true(
      has_line(
        lines,
        '- **<leader>b** file panel の表示トグル (閉じても tab とレビュー窓は残る)'
      )
    )
    assert.is_true(
      has_line(
        lines,
        '- **<leader>c** コメント一覧 (横断) をレビュー tab の最下部に全幅で開く'
          .. ' (:Review comments と同じ。既に開いていればその窓へ focus)'
      )
    )
    assert.is_true(has_line(lines, '- **i** カーソル行のコメントを閲覧 (read-only)'))
    assert.is_true(
      has_line(
        lines,
        '- **<CR>** そのファイルを head/base 窓に開く (カーソルは file panel に残る。dir 行では折り畳み)'
      )
    )
    assert.is_true(has_line(lines, '- **o** <CR> と同じ (file panel の o = entry を開く)'))
    assert.is_true(has_line(lines, '- **l** <CR> と同じ (entry を開く)'))
    -- file panel 節の移動系・refresh (review-18-r1 high 対策)。diff 節と同一文だと
    -- has_line 全文一致が節を区別できず、panel 側の 5 行を消しても緑になる
    -- (検出能力ゼロ)。doc/review.txt sidebar 節の文案で文言を一意化している。
    assert.is_true(
      has_line(
        lines,
        '- **<Tab>** 次のファイル (file panel の表示順 = <CR> と同一処理。focus も panel に残る。端は無動作)'
      )
    )
    assert.is_true(has_line(lines, '- **<S-Tab>** 前のファイル (上記と同じ規則)'))
    assert.is_true(has_line(lines, '- **[F** 最初のファイル (上記と同じ規則)'))
    assert.is_true(has_line(lines, '- **]F** 最後のファイル (上記と同じ規則)'))
    assert.is_true(has_line(lines, '- **R** 差分を再取得 (レビュー窓の R と同一)'))
    assert.is_true(
      has_line(lines, '- **i** list 表示 (フルパス 1 行) ⇄ tree 表示を切替')
    )
    assert.is_true(has_line(lines, '- **/** 一覧を絞り込む (空入力で解除)'))
    assert.is_true(has_line(lines, '- **<F1>** このヘルプ (file panel でも g? で開く)'))
    assert.is_true(
      has_line(lines, '- **x** レビュー完了マーク [✓] 切替 (open では付かない)')
    )
    -- コメント一覧への導線は diff 節と同一文にすると has_line が節を区別できず
    -- (検出能力ゼロ)、文言を一意化している。
    assert.is_true(
      has_line(lines, '- **<leader>c** コメント一覧 (横断) を開く (diff 窓と同じ)')
    )
    -- gate 不成立窓の 1 keystroke built-in 副作用の help 明記契約 (DESIGN 決定表
    -- 「review キーの実装」)。文案の正本はこの行。
    assert.is_true(
      has_line(
        lines,
        '- **注:** レビュー窓のキーは buffer-local + 押下時点の窓 role gate。gate を'
          .. '通らない窓 (ユーザーが自分の窓で開いた同じ実ファイルなど) では'
          .. ' 1 キーストロークが built-in 動作に戻る'
      )
    )
    -- コメント入力 float の操作 (ui/input.lua の契約と同一文言。確定/閉じるの
    -- discoverability を help 側でも保証する)
    assert.is_true(has_line(lines, '## コメント入力 (c/e で開く)'))
    assert.is_true(has_line(lines, '- **<CR>** 確定 (Normal)。insert 中の <CR> は改行'))
    assert.is_true(
      has_line(
        lines,
        '- **q** 閉じる。本文なし=キャンセル / 本文ありは閉じず、続けて q で破棄'
      )
    )
    assert.is_true(has_line(lines, '- **<C-y>** 確定 (insert)'))
    assert.is_true(has_line(lines, '- **<Esc>** Normal へ戻るだけ (窓は閉じない)'))
    assert.is_true(has_line(lines, '## セッション一覧 (:Review list)'))
    assert.is_true(
      has_line(lines, '- **d** 選択セッションを削除 (:Review delete と同じ確認)')
    )
    assert.is_true(has_line(lines, '## コメント一覧 (横断)'))
    assert.is_true(
      has_line(lines, '- **<CR>** カーソル行のコメント位置へジャンプ')
    )
    assert.is_true(
      has_line(
        lines,
        '- **d** カーソル行のコメントを削除 (一覧専用 arming: 同じ行でもう一度 d)'
      )
    )
    assert.is_true(has_line(lines, '- **e** カーソル行のコメントを編集'))
    assert.is_true(
      has_line(lines, '- **y** カーソル行のコメントのプロンプトを yank')
    )
    assert.is_true(
      has_line(lines, '- **q** 一覧を閉じる (セッション状態は変えない)')
    )
    vim.cmd 'normal q'
  end)

  it('q で閉じる', function()
    help.open()
    vim.cmd 'normal q'
    assert.equals(1, tab_wins())
  end)

  it('<Esc> で閉じる (DoD の <F1> help float 経路)', function()
    help.open()
    vim.cmd('normal ' .. ESC)
    assert.equals(1, tab_wins())
  end)

  it('keymaps override では表示キーが override 後の値に従う', function()
    config.setup { keymaps = { diff = { add_comment = 'gc' } } }
    help.open()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_true(
      has_line(lines, '- **gc** 作成コメント (visual-line で範囲指定・head 窓のみ)')
    )
    assert.is_false(
      has_line(lines, 'c 作成コメント (visual-line で範囲指定・head 窓のみ)')
    )
    vim.cmd 'normal q'
  end)
end)
