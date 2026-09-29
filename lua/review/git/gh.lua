-- gh CLI による PR 解決アダプタ (pr-worktree.md「PR 解決」手順 1)。
-- config.gh_bin 注入 (DESIGN.md「gh / git 実行」)。実行は git/cli と同じ境界で、
-- 不在は E_GH。失敗の使い分け: gh の stderr に未ログイン誘導文 (`gh auth login`)
-- があれば E_GH (通知文言を固定)、それ以外の失敗 (PR 非存在等) は E_PR。
-- 手続きは例外を投げず結果型で返す (DESIGN.md 横断規約)。
-- レビューコメントの取得・書き込み (pr-comments) は `gh api` 経由。
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

local JSON_FIELDS = 'number,title,baseRefName,headRefName,headRepositoryOwner,url,state'

--- `gh api` の共通実行。失敗の分類は pr_view と同じ規則 (未 auth = E_GH、
--- それ以外の HTTP/実行失敗 = E_PR)。opts.cwd は repo 作業ツリー (gh api は
--- owner/repo をパスに持つため cwd に依存しないが、認証環境に合わせて渡す)。
local function run_api(args, opts, cb)
  local cfg = config.get()
  cli.run(cfg.gh_bin, args, { cwd = opts.cwd, err_code = result.codes.E_GH }, function(res)
    if not res.ok then
      if res.data == nil then
        cb(res)
        return
      end
      local err = res.error or ''
      if err:lower():find('gh auth login', 1, true) ~= nil then
        res.error = 'gh is not logged in; run `gh auth login`'
        res.code = result.codes.E_GH
        cb(res)
        return
      end
      res.code = result.codes.E_PR
      cb(res)
      return
    end
    cb(res)
  end)
end

local function decode_json(res, label, cb)
  local ok_decode, decoded = pcall(vim.json.decode, res.data.stdout)
  if not ok_decode or type(decoded) ~= 'table' then
    cb(result.err('failed to parse the output of ' .. label, result.codes.E_GH))
    return
  end
  cb(result.ok(decoded))
end

-- 書き込み系 (POST / PUT) の共通実行。gh api の `-f`/`-F` フォームフィールドは
-- 全て文字列になり GitHub が整数フィールド (line / in_reply_to 等) を 422 で
-- 拒否する実測があるため、JSON body を一時ファイルに書いて `--input` で渡す。
-- 一時ファイルはコールバック完了時に削除する (クラッシュ時は /tmp に残る許容)。
local function run_api_json(args_prefix, payload, opts, cb)
  local file = vim.fn.tempname()
  local f = io.open(file, 'w')
  if f == nil then
    cb(result.err('failed to write the request body', result.codes.E_GH))
    return
  end
  f:write(vim.json.encode(payload))
  f:close()
  local args = vim.list_extend(args_prefix, { '--input', file })
  run_api(args, opts, function(res)
    pcall(os.remove, file)
    cb(res)
  end)
end

-- gh api の REST パス組み立て。opts.repo = { owner, repo }。

--- PR url (session.pr.url) から owner/repo を抜く。URL でなければ nil。
--- https://github.com/<owner>/<repo>/pull/<n> の先頭 2 セグメントを採用。
function M.repo_from_url(url)
  if type(url) ~= 'string' then
    return nil
  end
  local owner, repo = url:match '^https?://[^/]+/([^/]+)/([^/]+)'
  if owner == nil or repo == nil then
    return nil
  end
  return { owner = owner, repo = repo }
end

--- opts = { target = PR 番号 or URL, cwd? }。
--- cb(result) result.data = gh pr view の JSON (number, title, baseRefName,
--- headRefName, headRepositoryOwner, url, state)。
function M.pr_view(opts, cb)
  local cfg = config.get()
  cli.run(
    cfg.gh_bin,
    { 'pr', 'view', opts.target, '--json', JSON_FIELDS },
    { cwd = opts.cwd, err_code = result.codes.E_GH },
    function(res)
      if not res.ok then
        -- 不在・起動失敗 (data なし) は gh の実行に到達していない → E_GH のまま
        if res.data == nil then
          cb(res)
          return
        end
        local err = res.error or ''
        if err:lower():find('gh auth login', 1, true) ~= nil then
          -- 理由文字列のみ返す (通知プレフィックスは caller 側 — 横断規約の通知形式)
          res.error = 'gh is not logged in; run `gh auth login`'
          res.code = result.codes.E_GH
          cb(res)
          return
        end
        -- gh は走ったが PR を解決できない (非存在・repo 不一致等) = E_PR。
        -- stderr 末尾 1 行 (cli 整形済み) を理由としてそのまま返す。
        res.code = result.codes.E_PR
        cb(res)
        return
      end
      local ok_decode, meta = pcall(vim.json.decode, res.data.stdout)
      if not ok_decode or type(meta) ~= 'table' then
        cb(result.err('failed to parse the output of gh pr view', result.codes.E_GH))
        return
      end
      cb(result.ok(meta))
    end
  )
end

--- opts = { repo = {owner, repo}, number, cwd? }。
--- cb(result) data = 全レビューコメントの配列 (インライン + ファイルレベル、
--- 未 submit 含む)。GET repos/{o}/{r}/pulls/{n}/comments --paginate。
function M.list_review_comments(opts, cb)
  run_api(
    {
      'api',
      ('repos/%s/%s/pulls/%s/comments'):format(opts.repo.owner, opts.repo.repo, opts.number),
      '--paginate',
    },
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      decode_json(res, 'gh api list review comments', cb)
    end
  )
end

--- cb(result) data = レビュー (state: PENDING / COMMENTED / APPROVED /
--- CHANGES_REQUESTED / DISMISSED) の配列。コメントの submit 判定に使う。
function M.list_reviews(opts, cb)
  run_api(
    {
      'api',
      ('repos/%s/%s/pulls/%s/reviews'):format(opts.repo.owner, opts.repo.repo, opts.number),
      '--paginate',
    },
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      decode_json(res, 'gh api list reviews', cb)
    end
  )
end

--- cb(result) data = 一般コメント (conversation) の配列。
--- GET repos/{o}/{r}/issues/{n}/comments。
function M.list_issue_comments(opts, cb)
  run_api(
    {
      'api',
      ('repos/%s/%s/issues/%s/comments'):format(opts.repo.owner, opts.repo.repo, opts.number),
      '--paginate',
    },
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      decode_json(res, 'gh api list issue comments', cb)
    end
  )
end

--- レビューコメントの作成 (返信含む)。POST repos/{o}/{r}/pulls/{n}/comments。
--- opts = { repo, number, body, in_reply_to? | path, line?, start_line?,
---          subject_type? ('file' は line 不要), cwd? }。
--- in_reply_to 指定時は他パラメータを GitHub が無視する (返信 = スレッド継承)。
--- cb(result) data = 作成されたコメントオブジェクト。
function M.create_review_comment(opts, cb)
  local payload = { body = opts.body }
  if opts.in_reply_to ~= nil then
    payload.in_reply_to = opts.in_reply_to
  else
    payload.path = opts.path
    if opts.subject_type == 'file' then
      payload.subject_type = 'file'
    else
      payload.line = opts.line
      if opts.start_line ~= nil then
        payload.start_line = opts.start_line
        payload.side = 'RIGHT'
      end
    end
  end
  run_api_json(
    {
      'api',
      '--method',
      'POST',
      ('repos/%s/%s/pulls/%s/comments'):format(opts.repo.owner, opts.repo.repo, opts.number),
    },
    payload,
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      decode_json(res, 'gh api create review comment', cb)
    end
  )
end

--- 一般コメント (conversation) の投稿。POST repos/{o}/{r}/issues/{n}/comments。
--- opts = { repo, number, body, cwd? }。cb(result) data = 作成されたコメント。
function M.create_issue_comment(opts, cb)
  run_api_json(
    {
      'api',
      '--method',
      'POST',
      ('repos/%s/%s/issues/%s/comments'):format(opts.repo.owner, opts.repo.repo, opts.number),
    },
    { body = opts.body },
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      decode_json(res, 'gh api create issue comment', cb)
    end
  )
end

--- レビュー submit (コメント付きで 1 回のレビューとして確定)。
--- POST repos/{o}/{r}/pulls/{n}/reviews。
--- opts = { repo, number, event ('COMMENT'|'APPROVE'|'REQUEST_CHANGES'),
---          body?, comments? = [{ path, line, body }...], cwd? }。
--- comments は新規スレッドの行コメントの配列 (返信 in_reply_to やファイルレベル
--- subject_type は batch に載せられない — GitHub のスキーマ制約。個別 POST で送る)。
function M.create_review(opts, cb)
  local payload = { event = opts.event }
  if opts.body ~= nil and opts.body ~= '' then
    payload.body = opts.body
  end
  if opts.comments ~= nil and #opts.comments > 0 then
    payload.comments = opts.comments
  end
  run_api_json(
    {
      'api',
      '--method',
      'POST',
      ('repos/%s/%s/pulls/%s/reviews'):format(opts.repo.owner, opts.repo.repo, opts.number),
    },
    payload,
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      decode_json(res, 'gh api create review', cb)
    end
  )
end

--- 特定レビューに属するコメント一覧。GET repos/{o}/{r}/pulls/{n}/reviews/{id}/comments。
--- バッチ submit (create_review の comments) で作られたコメントの gh_id 対応付けに使う。
function M.list_review_comments_by_review(opts, cb)
  run_api(
    {
      'api',
      ('repos/%s/%s/pulls/%s/reviews/%s/comments'):format(
        opts.repo.owner,
        opts.repo.repo,
        opts.number,
        opts.review_id
      ),
      '--paginate',
    },
    opts,
    function(res)
      if not res.ok then
        cb(res)
        return
      end
      decode_json(res, 'gh api list review comments by review', cb)
    end
  )
end

return M
