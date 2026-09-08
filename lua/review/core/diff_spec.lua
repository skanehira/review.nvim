-- core/diff: 実 git で生成した生出力をパースし、ファイル → hunk → 行種別 →
-- new 側行番号の写像を導く (DESIGN.md「既知の制約」hunk ヘッダからの行番号換算)。
-- 期待値表は git 2.55 の生出力実測に基づく (multi-hunk / rename / binary /
-- 新規 / 削除 / 0 行数 hunk / 複数ファイル連なり)。フィクスチャは毎回
-- 一意ディレクトリに実 repo を作り、終了掃除する (DESIGN.md「開発・検証コマンド」)。
local diff = require 'review.core.diff'

local created_dirs = {}

local function git_repo(dir, args)
  local cmd = vim.list_extend({ 'git' }, vim.deepcopy(args))
  local out = vim.system(cmd, { cwd = dir, text = true }):wait(15000)
  if out.code ~= 0 then
    error(
      'git '
        .. table.concat(args, ' ')
        .. ' は終了コード '
        .. tostring(out.code)
        .. ' で失敗: '
        .. tostring(out.stderr),
      0
    )
  end
  return out.stdout
end

local function write_file(dir, name, content)
  local path = vim.fs.joinpath(dir, name)
  local f = io.open(path, 'wb')
  if f == nil then
    error('spec fixture の書き込み失敗: ' .. path, 0)
  end
  f:write(content)
  f:close()
end

local function new_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  table.insert(created_dirs, dir)
  git_repo(dir, { 'init', '-q', '-b', 'main' })
  git_repo(dir, { 'config', 'user.email', 'spec@example.com' })
  git_repo(dir, { 'config', 'user.name', 'review.nvim spec' })
  git_repo(dir, { 'config', 'commit.gpgsign', 'false' })
  return dir
end

local function commit(dir, message)
  git_repo(dir, { 'add', '-A' })
  git_repo(dir, { 'commit', '-qm', message })
end

local function feature_branch(dir)
  git_repo(dir, { 'checkout', '-qb', 'feature' })
end

-- git diff main feature [...flags] の生出力。
local function diff_raw(dir, ...)
  local args = { 'diff' }
  for _, flag in ipairs { ... } do
    table.insert(args, flag)
  end
  table.insert(args, 'main')
  table.insert(args, 'feature')
  return git_repo(dir, args)
end

local function cleanup_dirs()
  after_each(function()
    for _, dir in ipairs(created_dirs) do
      vim.fn.delete(dir, 'rf')
    end
    created_dirs = {}
  end)
end

-- パース結果の骨格 (ファイル順・path・変更種別・追加/削除行数・hunk 数)。
-- 行の正しさは new 側行番号を伴う全体比較で検証し、こちらはファイル分割と
-- 件数 (DoD の行数判定が新側番号ではなくファイル状態であることの担保) に使う。
local function skeleton(files)
  local out = {}
  for i, file in ipairs(files) do
    out[i] = {
      path = file.path,
      status = file.status,
      binary = file.binary,
      added = file.added,
      deleted = file.deleted,
      hunks = #file.hunks,
    }
  end
  return out
end

local function find_file(files, path)
  for _, file in ipairs(files) do
    if file.path == path then
      return file
    end
  end
  return error(
    'パース結果に ' .. path .. ' が無い (ファイル分割または path 導出の欠陥)',
    0
  )
end

describe('core/diff multi-hunk', function()
  cleanup_dirs()

  it(
    '同一ファイル複数 hunk で context/+ 行の new 側行番号が hunk 先頭からの累計と完全一致する',
    function()
      local dir = new_repo()
      write_file(
        dir,
        'a.txt',
        'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n'
      )
      commit(dir, 'base')
      feature_branch(dir)
      write_file(
        dir,
        'a.txt',
        'line1\nCHANGED2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nADDED11\n'
      )
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'a.txt', status = 'M', binary = false, added = 2, deleted = 1, hunks = 2 },
      }, skeleton(files))
      assert.same({
        path = 'a.txt',
        status = 'M',
        binary = false,
        added = 2,
        deleted = 1,
        hunks = {
          {
            old_start = 1,
            old_count = 5,
            new_start = 1,
            new_count = 5,
            header = '@@ -1,5 +1,5 @@',
            lines = {
              { kind = 'context', text = 'line1', new_line = 1 },
              { kind = 'del', text = 'line2' },
              { kind = 'add', text = 'CHANGED2', new_line = 2 },
              { kind = 'context', text = 'line3', new_line = 3 },
              { kind = 'context', text = 'line4', new_line = 4 },
              { kind = 'context', text = 'line5', new_line = 5 },
            },
          },
          {
            old_start = 8,
            old_count = 3,
            new_start = 8,
            new_count = 4,
            header = '@@ -8,3 +8,4 @@ line7',
            lines = {
              { kind = 'context', text = 'line8', new_line = 8 },
              { kind = 'context', text = 'line9', new_line = 9 },
              { kind = 'context', text = 'line10', new_line = 10 },
              { kind = 'add', text = 'ADDED11', new_line = 11 },
            },
          },
        },
      }, files[1])
    end
  )

  it('生出力が空 (差分 0 ファイル) は空のファイル一覧になる', function()
    assert.same({}, diff.parse '')
  end)
end)

describe('core/diff rename', function()
  cleanup_dirs()

  it(
    'rename from/to を伴う変更を new-name.txt 1 ファイルとしてパースし、old-name.txt は残さない',
    function()
      local dir = new_repo()
      write_file(dir, 'old-name.txt', 'x1\nx2\nx3\nx4\nx5\nx6\n')
      write_file(dir, 'keep.txt', 'keep\n')
      commit(dir, 'base')
      feature_branch(dir)
      git_repo(dir, { 'mv', 'old-name.txt', 'new-name.txt' })
      write_file(dir, 'new-name.txt', 'x1\nchanged2\nx3\nx4\nx5\nx6\n')
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({ 'new-name.txt' }, { files[1].path })
      assert.equals(1, #files)
      assert.same({
        path = 'new-name.txt',
        status = 'R',
        binary = false,
        added = 1,
        deleted = 1,
        hunks = {
          {
            old_start = 1,
            old_count = 5,
            new_start = 1,
            new_count = 5,
            header = '@@ -1,5 +1,5 @@',
            lines = {
              { kind = 'context', text = 'x1', new_line = 1 },
              { kind = 'del', text = 'x2' },
              { kind = 'add', text = 'changed2', new_line = 2 },
              { kind = 'context', text = 'x3', new_line = 3 },
              { kind = 'context', text = 'x4', new_line = 4 },
              { kind = 'context', text = 'x5', new_line = 5 },
            },
          },
        },
      }, files[1])
    end
  )
end)

describe('core/diff binary', function()
  cleanup_dirs()

  it(
    '変更されたバイナリ (Binary files a/.. b/.. differ) は binary=true・hunk ゼロの M になる',
    function()
      local dir = new_repo()
      write_file(dir, 'bin.dat', '\0\1\2bin-v1')
      write_file(dir, 'keep.txt', 'keep\n')
      commit(dir, 'base')
      feature_branch(dir)
      write_file(dir, 'bin.dat', '\0\1\3bin-v2\0extra')
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'bin.dat', status = 'M', binary = true, added = 0, deleted = 0, hunks = 0 },
      }, skeleton(files))
      assert.same({
        path = 'bin.dat',
        status = 'M',
        binary = true,
        added = 0,
        deleted = 0,
        hunks = {},
      }, files[1])
    end
  )

  it(
    '新規バイナリ (Binary files /dev/null and b/.. differ) は path=new・status=A',
    function()
      local dir = new_repo()
      write_file(dir, 'keep.txt', 'keep\n')
      commit(dir, 'base')
      feature_branch(dir)
      write_file(dir, 'bin-add.dat', '\0\t newbin')
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'bin-add.dat', status = 'A', binary = true, added = 0, deleted = 0, hunks = 0 },
      }, skeleton(files))
    end
  )

  it(
    '削除バイナリ (Binary files a/.. and /dev/null differ) は path=旧・status=D',
    function()
      local dir = new_repo()
      write_file(dir, 'bin-del.dat', '\0\1 deletebin')
      write_file(dir, 'keep.txt', 'keep\n')
      commit(dir, 'base')
      feature_branch(dir)
      vim.fn.delete(vim.fs.joinpath(dir, 'bin-del.dat'))
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'bin-del.dat', status = 'D', binary = true, added = 0, deleted = 0, hunks = 0 },
      }, skeleton(files))
    end
  )
end)

describe('core/diff 新規・削除', function()
  cleanup_dirs()

  it(
    '新規テキストは new file mode・全行 add・old 側 0 行 hunk で導出される',
    function()
      local dir = new_repo()
      write_file(dir, 'note.txt', 'note\n')
      commit(dir, 'base')
      feature_branch(dir)
      write_file(dir, 'new.txt', 'c1\nc2\n')
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'new.txt', status = 'A', binary = false, added = 2, deleted = 0, hunks = 1 },
      }, skeleton(files))
      assert.same({
        path = 'new.txt',
        status = 'A',
        binary = false,
        added = 2,
        deleted = 0,
        hunks = {
          {
            old_start = 0,
            old_count = 0,
            new_start = 1,
            new_count = 2,
            header = '@@ -0,0 +1,2 @@',
            lines = {
              { kind = 'add', text = 'c1', new_line = 1 },
              { kind = 'add', text = 'c2', new_line = 2 },
            },
          },
        },
      }, files[1])
    end
  )

  it(
    '空ファイルの新規 (new file mode のみ・hunk なし) は行を持たない A になる',
    function()
      local dir = new_repo()
      write_file(dir, 'note.txt', 'note\n')
      commit(dir, 'base')
      feature_branch(dir)
      write_file(dir, 'empty.txt', '')
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'empty.txt', status = 'A', binary = false, added = 0, deleted = 0, hunks = 0 },
      }, skeleton(files))
    end
  )

  it(
    '全削除ファイルは deleted file mode・@@ -1,5 +0,0 @@・全行 del (new 側行番号なし)',
    function()
      local dir = new_repo()
      write_file(dir, 'b.txt', 'b1\nb2\nb3\nb4\nb5\n')
      write_file(dir, 'note.txt', 'note\n')
      commit(dir, 'base')
      feature_branch(dir)
      vim.fn.delete(vim.fs.joinpath(dir, 'b.txt'))
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'b.txt', status = 'D', binary = false, added = 0, deleted = 5, hunks = 1 },
      }, skeleton(files))
      assert.same({
        path = 'b.txt',
        status = 'D',
        binary = false,
        added = 0,
        deleted = 5,
        hunks = {
          {
            old_start = 1,
            old_count = 5,
            new_start = 0,
            new_count = 0,
            header = '@@ -1,5 +0,0 @@',
            lines = {
              { kind = 'del', text = 'b1' },
              { kind = 'del', text = 'b2' },
              { kind = 'del', text = 'b3' },
              { kind = 'del', text = 'b4' },
              { kind = 'del', text = 'b5' },
            },
          },
        },
      }, files[1])
    end
  )

  it(
    '空ファイルの削除は new/deleted file マーカーのみで ---/+++ 無くても path を導く',
    function()
      local dir = new_repo()
      write_file(dir, 'empty-del.txt', '')
      write_file(dir, 'note.txt', 'note\n')
      commit(dir, 'base')
      feature_branch(dir)
      vim.fn.delete(vim.fs.joinpath(dir, 'empty-del.txt'))
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'empty-del.txt', status = 'D', binary = false, added = 0, deleted = 0, hunks = 0 },
      }, skeleton(files))
    end
  )
end)

describe('core/diff 0 行数 hunk (-U0)', function()
  cleanup_dirs()

  it(
    '+1,0 hunk は new 側行数 0 として全行に new 側行番号を生成せず、-1,0 hunk の add 行は指定番号になる',
    function()
      local dir = new_repo()
      write_file(dir, 'tail.txt', 't1\nt2\n')
      write_file(dir, 'tail2.txt', 't1\n')
      commit(dir, 'base')
      feature_branch(dir)
      write_file(dir, 'tail.txt', 't1\n')
      write_file(dir, 'tail2.txt', 't1\nt2\n')
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir, '-U0'))

      assert.same({
        { path = 'tail.txt', status = 'M', binary = false, added = 0, deleted = 1, hunks = 1 },
        { path = 'tail2.txt', status = 'M', binary = false, added = 1, deleted = 0, hunks = 1 },
      }, skeleton(files))
      assert.same({
        path = 'tail.txt',
        status = 'M',
        binary = false,
        added = 0,
        deleted = 1,
        hunks = {
          {
            old_start = 2,
            old_count = 1,
            new_start = 1,
            new_count = 0,
            header = '@@ -2 +1,0 @@ t1',
            lines = { { kind = 'del', text = 't2' } },
          },
        },
      }, find_file(files, 'tail.txt'))
      assert.same({
        path = 'tail2.txt',
        status = 'M',
        binary = false,
        added = 1,
        deleted = 0,
        hunks = {
          {
            old_start = 1,
            old_count = 0,
            new_start = 2,
            new_count = 1,
            header = '@@ -1,0 +2 @@ t1',
            lines = { { kind = 'add', text = 't2', new_line = 2 } },
          },
        },
      }, find_file(files, 'tail2.txt'))
    end
  )
end)

describe('core/diff モード変更のみ', function()
  cleanup_dirs()

  it(
    'old mode/new mode のみ変更は ---/+++ 行が無くても diff --git 行から path を導く',
    function()
      local dir = new_repo()
      write_file(dir, 'keep.txt', 'keep\n')
      commit(dir, 'base')
      feature_branch(dir)
      local chmod = vim.system({ 'chmod', '755', vim.fs.joinpath(dir, 'keep.txt') }):wait(5000)
      assert(chmod.code == 0, 'spec fixture の chmod 失敗')
      commit(dir, 'feat')

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'keep.txt', status = 'M', binary = false, added = 0, deleted = 0, hunks = 0 },
      }, skeleton(files))
    end
  )
end)

describe('core/diff 複数ファイル連なり', function()
  cleanup_dirs()

  local function build_combo_repo()
    local dir = new_repo()
    write_file(
      dir,
      'a.txt',
      'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n'
    )
    write_file(dir, 'b.txt', 'b1\nb2\nb3\nb4\nb5\n')
    write_file(dir, 'bin.dat', '\0\1\2bin-v1')
    write_file(dir, 'keep.txt', 'keep\n')
    write_file(dir, 'nn.txt', 'v1')
    write_file(dir, 'old-name.txt', 'x1\nx2\nx3\nx4\nx5\nx6\n')
    write_file(dir, 'tail.txt', 't1\nt2\n')
    write_file(dir, 'tail2.txt', 't1\n')
    commit(dir, 'base')
    feature_branch(dir)
    write_file(
      dir,
      'a.txt',
      'line1\nCHANGED2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nADDED11\n'
    )
    vim.fn.delete(vim.fs.joinpath(dir, 'b.txt'))
    write_file(dir, 'bin.dat', '\0\1\3bin-v2\0extra')
    write_file(dir, 'empty.txt', '')
    write_file(dir, 'nn.txt', 'x1\nx2\nx3\nx4\nx5')
    git_repo(dir, { 'mv', 'old-name.txt', 'new-name.txt' })
    write_file(dir, 'new-name.txt', 'x1\nchanged2\nx3\nx4\nx5\nx6\n')
    write_file(dir, 'tail.txt', 't1\n')
    write_file(dir, 'tail2.txt', 't1\nt2\n')
    commit(dir, 'feat')
    return dir
  end

  it(
    '8 種の差分が連なる生出力でファイル分割・順序・行数・hunk 数がすべて実 git と一致する',
    function()
      local dir = build_combo_repo()

      local files = diff.parse(diff_raw(dir))

      assert.same({
        { path = 'a.txt', status = 'M', binary = false, added = 2, deleted = 1, hunks = 2 },
        { path = 'b.txt', status = 'D', binary = false, added = 0, deleted = 5, hunks = 1 },
        { path = 'bin.dat', status = 'M', binary = true, added = 0, deleted = 0, hunks = 0 },
        { path = 'empty.txt', status = 'A', binary = false, added = 0, deleted = 0, hunks = 0 },
        { path = 'new-name.txt', status = 'R', binary = false, added = 1, deleted = 1, hunks = 1 },
        { path = 'nn.txt', status = 'M', binary = false, added = 5, deleted = 1, hunks = 1 },
        { path = 'tail.txt', status = 'M', binary = false, added = 0, deleted = 1, hunks = 1 },
        { path = 'tail2.txt', status = 'M', binary = false, added = 1, deleted = 0, hunks = 1 },
      }, skeleton(files))
    end
  )

  it(
    '\\ No newline at end of file マーカーを行として含まず、行数換算もずれない',
    function()
      local dir = build_combo_repo()

      local files = diff.parse(diff_raw(dir))
      local nn = find_file(files, 'nn.txt')

      assert.same({
        path = 'nn.txt',
        status = 'M',
        binary = false,
        added = 5,
        deleted = 1,
        hunks = {
          {
            old_start = 1,
            old_count = 1,
            new_start = 1,
            new_count = 5,
            header = '@@ -1 +1,5 @@',
            lines = {
              { kind = 'del', text = 'v1' },
              { kind = 'add', text = 'x1', new_line = 1 },
              { kind = 'add', text = 'x2', new_line = 2 },
              { kind = 'add', text = 'x3', new_line = 3 },
              { kind = 'add', text = 'x4', new_line = 4 },
              { kind = 'add', text = 'x5', new_line = 5 },
            },
          },
        },
      }, nn)
    end
  )

  it('行数省略ヘッダ (@@ -1,2 +1 @@) も new 側行数 1 として換算する', function()
    local dir = build_combo_repo()

    local files = diff.parse(diff_raw(dir))
    local tail = find_file(files, 'tail.txt')

    assert.same({
      path = 'tail.txt',
      status = 'M',
      binary = false,
      added = 0,
      deleted = 1,
      hunks = {
        {
          old_start = 1,
          old_count = 2,
          new_start = 1,
          new_count = 1,
          header = '@@ -1,2 +1 @@',
          lines = {
            { kind = 'context', text = 't1', new_line = 1 },
            { kind = 'del', text = 't2' },
          },
        },
      },
    }, tail)
  end)
end)
