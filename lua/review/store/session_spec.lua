-- セッション JSON 永続化の検証 (DESIGN.md「データスキーマ」が全フィールドの正本、
-- persistence-restore.md「入出力と振る舞い」保存 / 読込)。
-- tmpdir を paths._set_data_dir に注入して本物の stdpath を汚さない。
-- rename / now / notify はファイルシステム・時刻・通知の境界なので DI スタブ
-- (testing.md 優先順位①)。repo フィクスチャは固定偽パス '/repo-x' で足りる
-- (save/load は repo の実在を要求せず、sha1('/repo-x') 先頭 16 桁が
-- ディレクトリ名を決めるだけ。REPO_HASH は shasum 実測値)。

local paths = require 'review.store.paths'
local session = require 'review.store.session'

local REPO = '/repo-x'
local REPO_HASH = 'f90cc21f45278cc2'
local FIXED_NOW = 1234

local function join(...)
  return table.concat({ ... }, '/')
end

local function repo_dir_of(dir)
  return join(dir, 'review.nvim', 'sessions', REPO_HASH)
end

local function session_file_of(dir, slug)
  return repo_dir_of(dir) .. '/' .. slug .. '.json'
end

-- DESIGN.md「データスキーマ」の全フィールドを持つセッション。
local function sample(overrides)
  local s = {
    version = 1,
    id = 'main--feature',
    repo = REPO,
    mode = 'branch',
    base = 'main',
    head = 'feature',
    pr = vim.NIL,
    worktree = vim.NIL,
    status = 'open',
    files = { ['lib/x.lua'] = { viewed = false }, ['main.go'] = { viewed = true } },
    comments = {
      {
        id = 'c1',
        file = 'lib/x.lua',
        line = 10,
        end_line = 12,
        body = '1st line\n2nd line',
        anchor = { before = 'local x = 1', line = 'return x', after = vim.NIL },
        state = 'active',
        created_at = 1000,
      },
    },
    created_at = 900,
    updated_at = FIXED_NOW,
  }
  for key, value in pairs(overrides or {}) do
    s[key] = value
  end
  return s
end

-- tmpdir 注入・固定 now・notify 記録を各テスト前后に設定する状態ヘルパ。
-- 返り値の state から dir / notices をテスト本体で参照する。
local function isolate_store()
  local state = {}
  before_each(function()
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    state.notices = {}
    paths._set_data_dir(state.dir)
    session._set_now(function()
      return FIXED_NOW
    end)
    session._set_rename(nil)
    session._set_notify(function(msg, level)
      table.insert(state.notices, { msg = msg, level = level })
    end)
  end)
  after_each(function()
    paths._set_data_dir(nil)
    session._set_now(nil)
    session._set_rename(nil)
    session._set_notify(nil)
    vim.fn.delete(state.dir, 'rf')
  end)
  return state
end

describe('save→load 往復', function()
  local state = isolate_store()

  it(
    '保存すると実配置 <data>/review.nvim/sessions/<repo-hash>/<slug>.json に作られる',
    function()
      local res = session.save(sample())
      assert.same({ __class = 'review.Result', ok = true }, res)
      -- ディレクトリ名は shasum 実測値 REPO_HASH のリテラルで固定 (paths 実装経由でない)。
      -- 中身は JSON decode 後に全体比較する (encode のキー順は Lua table 走査順依存で
      -- バイト一致は仕様ではない)。
      local on_disk = vim.json.decode(
        table.concat(vim.fn.readfile(session_file_of(state.dir, 'main--feature')), '\n')
      )
      assert.same(sample(), on_disk)
    end
  )

  it(
    '読み戻しは DESIGN.md スキーマ全フィールド同一のセッション (JSON 往復)',
    function()
      session.save(sample())
      assert.same(
        { __class = 'review.Result', ok = true, data = sample() },
        session.load(REPO, 'main--feature')
      )
    end
  )

  it('save は呼び出し側のセッションテーブルを変更しない', function()
    local input = sample()
    input.updated_at = 999
    local before = vim.deepcopy(input)
    session.save(input)
    assert.same(before, input)
  end)

  it('updated_at は保存時に注入時刻で上書きして書かれる', function()
    local input = sample()
    input.updated_at = 999
    session.save(input)
    assert.same(
      { __class = 'review.Result', ok = true, data = sample() },
      session.load(REPO, 'main--feature')
    )
  end)

  it(
    'version は保存時にスキーマ version 1 で正規化される (store が正本)',
    function()
      session.save(sample { version = 4 })
      assert.same(
        { __class = 'review.Result', ok = true, data = sample() },
        session.load(REPO, 'main--feature')
      )
    end
  )

  it(
    'os.rename は tmp→セッションファイルへ呼ばれる (同一 dir tmp + rename)',
    function()
      local calls = {}
      session._set_rename(function(from, to)
        table.insert(calls, { from = from, to = to })
        return os.rename(from, to)
      end)
      session.save(sample())
      local file = session_file_of(state.dir, 'main--feature')
      assert.same({ { from = file .. '.tmp', to = file } }, calls)
    end
  )

  it(
    '再 save はセッションファイルを 1 個のまま最新内容へ差し替える',
    function()
      session.save(sample())
      local closed = vim.deepcopy(sample())
      closed.status = 'closed'
      session.save(closed)
      assert.same(
        { __class = 'review.Result', ok = true, data = closed },
        session.load(REPO, 'main--feature')
      )
    end
  )
end)

describe('save 失敗は E_STORE', function()
  local state = isolate_store()

  it(
    'rename 失敗注入の save は E_STORE を返し、ディスクは前回内容を維持',
    function()
      session.save(sample())
      session._set_now(function()
        return 5678
      end)
      session._set_rename(function()
        return nil, 'EPERM: operation not permitted'
      end)
      local input = vim.deepcopy(sample())
      input.status = 'closed'
      local file = session_file_of(state.dir, 'main--feature')
      assert.same({
        __class = 'review.Result',
        ok = false,
        error = 'セッションファイルの差し替えに失敗しました: '
          .. file
          .. ' (EPERM: operation not permitted)',
        code = 'E_STORE',
      }, session.save(input))
      -- 元の内容 (open / updated_at 1234) がそのまま残っている
      assert.same(
        { __class = 'review.Result', ok = true, data = sample() },
        session.load(REPO, 'main--feature')
      )
    end
  )

  it(
    'rename 失敗後の save は、次 save 成功で再挑戦として効く (INV-4 の留保)',
    function()
      session.save(sample())
      session._set_rename(function()
        return nil, 'EPERM: operation not permitted'
      end)
      local closed = vim.deepcopy(sample())
      closed.status = 'closed'
      assert.equals(false, session.save(closed).ok)

      session._set_rename(nil)
      assert.same({ __class = 'review.Result', ok = true }, session.save(closed))
      assert.same(
        { __class = 'review.Result', ok = true, data = closed },
        session.load(REPO, 'main--feature')
      )
    end
  )
end)

describe('load: 不在・破損退避・version 不一致', function()
  local state = isolate_store()

  it(
    '存在しないセッションの load は「存在しない」= data nil の ok (無通知)',
    function()
      assert.same({ __class = 'review.Result', ok = true }, session.load(REPO, 'main--feature'))
      -- 真の不在は読取不能 (下記テスト) と違い無通知。通知を出さない側も
      -- 契約 (persistence-restore.md「読込」) なので全比較で pin する。
      assert.same({}, state.notices)
    end
  )

  it(
    '実在するが読み取れないファイルは退避せず WARN のみで「存在しない」扱い',
    function()
      -- 権限を落として実在・読取不能 (EACCES) を再現 (tmpdir 注入なので本物環境不汚染)。
      local file = session_file_of(state.dir, 'main--feature')
      vim.fn.mkdir(repo_dir_of(state.dir), 'p')
      vim.fn.writefile({ 'SECRET' }, file)
      vim.fn.setfperm(file, '---------')

      assert.same({ __class = 'review.Result', ok = true }, session.load(REPO, 'main--feature'))
      assert.same({
        {
          msg = 'review.nvim: セッションファイル '
            .. file
            .. ' が読み取れません。「存在しない」として扱います',
          level = vim.log.levels.WARN,
        },
      }, state.notices)

      -- 退避した破損 JSON と違い、読み取れない状態は変わらないので再試行のたび WARN
      -- (抑止状態を持たないこともここで pin。退避と違い .corrupt は作られない)。
      assert.same({ __class = 'review.Result', ok = true }, session.load(REPO, 'main--feature'))

      -- 退避されず元ファイルはその場に残る: 権限を戻すと読める状態で、
      -- load を繰り返しても内容が変わっていない (退避が走っていたら読み出せない)。
      vim.fn.setfperm(file, 'rw-r--r--')
      assert.same({ 'SECRET' }, vim.fn.readfile(file))
      assert.same({
        {
          msg = 'review.nvim: セッションファイル '
            .. file
            .. ' が読み取れません。「存在しない」として扱います',
          level = vim.log.levels.WARN,
        },
        {
          msg = 'review.nvim: セッションファイル '
            .. file
            .. ' が読み取れません。「存在しない」として扱います',
          level = vim.log.levels.WARN,
        },
      }, state.notices)
    end
  )

  it(
    '破損 JSON は load 時に .corrupt へ退避され「存在しない」扱い + WARN',
    function()
      local file = session_file_of(state.dir, 'main--feature')
      vim.fn.mkdir(repo_dir_of(state.dir), 'p')
      vim.fn.writefile({ '{ this is not JSON' }, file)

      assert.same({ __class = 'review.Result', ok = true }, session.load(REPO, 'main--feature'))
      assert.same({ '{ this is not JSON' }, vim.fn.readfile(file .. '.corrupt'))
      local expected_note = {
        msg = 'review.nvim: 破損 JSON のセッションファイル '
          .. file
          .. ' を '
          .. file
          .. '.corrupt に退避しました',
        level = vim.log.levels.WARN,
      }
      assert.same({ expected_note }, state.notices)

      -- 以降の load は退避済みで「存在しない」扱いのまま (WARN 重複なし)
      assert.same({ __class = 'review.Result', ok = true }, session.load(REPO, 'main--feature'))
      assert.same({ expected_note }, state.notices)
    end
  )

  it(
    '破損退避後の save は新規ファイル作成として働く (.corrupt は残る)',
    function()
      local file = session_file_of(state.dir, 'main--feature')
      vim.fn.mkdir(repo_dir_of(state.dir), 'p')
      vim.fn.writefile({ '{{{' }, file)
      session.load(REPO, 'main--feature')

      assert.same({ __class = 'review.Result', ok = true }, session.save(sample()))
      assert.same(
        { __class = 'review.Result', ok = true, data = sample() },
        session.load(REPO, 'main--feature')
      )
      assert.same({ '{{{' }, vim.fn.readfile(file .. '.corrupt'))
    end
  )

  it(
    'version 不一致ファイルも退避され「存在しない」扱い + version 明示の WARN',
    function()
      local file = session_file_of(state.dir, 'main--feature')
      vim.fn.mkdir(repo_dir_of(state.dir), 'p')
      local future = vim.deepcopy(sample())
      future.version = 2
      local future_json = vim.json.encode(future)
      vim.fn.writefile({ future_json }, file)

      assert.same({ __class = 'review.Result', ok = true }, session.load(REPO, 'main--feature'))
      assert.same({ future_json }, vim.fn.readfile(file .. '.corrupt'))
      assert.same({
        {
          msg = 'review.nvim: schema version 不一致 (version=2) のセッションファイル '
            .. file
            .. ' を '
            .. file
            .. '.corrupt に退避しました',
          level = vim.log.levels.WARN,
        },
      }, state.notices)
    end
  )

  it(
    '退避時に既存 .corrupt がある場合は上書きされる (自動削除なく片付けは手動)',
    function()
      local file = session_file_of(state.dir, 'main--feature')
      vim.fn.mkdir(repo_dir_of(state.dir), 'p')
      vim.fn.writefile({ 'PREV-DATA' }, file .. '.corrupt')
      vim.fn.writefile({ '{ bad' }, file)

      session.load(REPO, 'main--feature')
      -- POSIX rename の上書き意味論が正本 (退避は 1 世代、履歴は保持しない)
      assert.same({ '{ bad' }, vim.fn.readfile(file .. '.corrupt'))
    end
  )
end)

describe('list', function()
  local state = isolate_store()

  it('当該 repo の全セッションを status を問わず返す', function()
    local open = sample()
    session.save(open)
    local closed = vim.deepcopy(sample())
    closed.id = 'main--bugfix'
    closed.head = 'bugfix'
    closed.status = 'closed'
    session.save(closed)

    local res = session.list(REPO)
    assert.equals(true, res.ok)
    local by_id = {}
    for _, s in ipairs(res.data) do
      by_id[s.id] = s
    end
    assert.same({ ['main--feature'] = open, ['main--bugfix'] = closed }, by_id)
  end)

  it('保存実績が無い repo の list は空配列を返す', function()
    assert.same({ __class = 'review.Result', ok = true, data = {} }, session.list(REPO))
  end)

  it(
    'list は .corrupt と非 .json を読み、破損 .json は退避して除外する',
    function()
      local open = sample()
      session.save(open)
      local dir = repo_dir_of(state.dir)
      vim.fn.writefile({ 'junk' }, join(dir, 'main--feature.json.corrupt'))
      vim.fn.writefile({ 'junk' }, join(dir, 'notes.txt'))
      vim.fn.writefile({ '{ no' }, join(dir, 'broken.json'))

      local res = session.list(REPO)
      assert.equals(true, res.ok)
      local by_id = {}
      for _, s in ipairs(res.data) do
        by_id[s.id] = s
      end
      assert.same({ ['main--feature'] = open }, by_id)
      assert.same({ '{ no' }, vim.fn.readfile(join(dir, 'broken.json.corrupt')))
    end
  )
end)
