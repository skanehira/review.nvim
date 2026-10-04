-- handlers/session: PR セッションの worktree 作成判断 (pr-worktree.md「worktree 作成判断」)。
-- mode=pr は常に worktree を作って差分は worktree 基準で取る。add 失敗時の prune 再試行、
-- 同一 dir path の登録変更の直列化 (wt_with_lock)、競合時の挙動を応答キュー stub で pin する。
-- 共有の開始部品は tests/helpers/session_fixtures.lua (session_spec と同じ土俵)。
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local session_env = require 'helpers.session_env'
local sf = require 'helpers.session_fixtures'

local SLUG = sf.SLUG
local SIDEBAR_NAME = sf.SIDEBAR_NAME
local RAW_DIFF_A_B = sf.RAW_DIFF_A_B
local state = sf.state
local install_git = sf.install_git
local install_git_deferred_remove = sf.install_git_deferred_remove
local diff_ok = sf.diff_ok
local load_saved = sf.load_saved
local existing_stub = sf.existing_stub
local wt_path = sf.wt_path
local git_fail = sf.git_fail
local has_call = sf.has_call
local use_env = sf.use_env
local git_ok = sf.git_ok
local begin_pr = sf.begin_pr
local head_buf_name = session_env.head_buf_name

local function add_cmd(ref, slug)
  return { 'git', 'worktree', 'add', '--detach', wt_path(slug), ref or 'feature' }
end

local function list_cmd()
  return { 'git', 'worktree', 'list', '--porcelain' }
end

describe(
  'pr worktree 作成判断 (mode=pr は常時作って差分は worktree 基準)',
  function()
    use_env()

    it(
      'pr: add --detach -> cwd=worktree の単引数 git diff <base> -> created_by_us=true 記録',
      function()
        begin_pr {
          git_ok, -- add
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }

        assert.same(add_cmd(), state.git_calls[1])
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[2])
        -- dir 実在しない (stub add) ため open 充填の show cwd は repo 基準
        assert.same({ 'git', 'show', 'main:a.lua' }, state.git_calls[3])
        assert.equals(state.repo, state.git_opts[3].cwd)
        assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
        assert.equals(0, #state.notifications)
        assert.equals(SLUG, session_handler.active().id)
      end
    )

    it('add 失敗 -> `git worktree prune` 再試行 recover -> diff まで到達', function()
      begin_pr {
        git_fail 'fatal: already registered\n', -- add1
        git_ok, -- prune
        git_ok, -- add2
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      assert.same(add_cmd(), state.git_calls[3])
      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[2])
      assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
    end)

    it(
      '作成失敗 (prune でも解消せず) は E_WORKTREE 案内で中断。diff は作成前に走らない (save なし・UI なし)',
      function()
        begin_pr {
          git_fail('fatal: ' .. wt_path() .. ' already exists\n'), -- add1
          git_ok, -- prune
          git_fail('fatal: ' .. wt_path() .. ' already exists\n'), -- add2
        }

        assert.same(
          (
            'review.nvim: cannot create the worktree: %s. if a worktree '
            .. 'with the same name is left over, '
            .. 'clean it up with `git worktree remove` and retry (fatal: %s already exists)'
          ):format(wt_path(), wt_path()),
          state.notifications[1].msg
        )
        assert.equals(vim.log.levels.WARN, state.notifications[1].level)
        assert.equals(1, #state.notifications)
        assert.is_false(has_call 'git diff')
        assert.is_nil(load_saved())
        assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
        assert.is_nil(session_handler.active())
      end
    )

    it(
      '記録済み worktree: dir 実在 + git list 登録あり => add せず再利用 (crash 後再開)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        -- 再利用する worktree の a.lua を実在させる (head 実ファイル窓の前提)
        local wf = io.open(vim.fs.joinpath(wt, 'a.lua'), 'w')
        wf:write 'WT-HEAD-CONTENT\n'
        wf:close()
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })

        begin_pr {
          function()
            return {
              code = 0,
              stdout = 'worktree ' .. state.repo .. '\nworktree ' .. vim.uv.fs_realpath(wt) .. '\n',
              stderr = '',
            }
          end, -- list: 登録あり
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }

        assert.is_false(has_call 'git worktree add')
        assert.same(list_cmd(), state.git_calls[1])
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[2])
        assert.equals(wt, state.git_opts[2].cwd)
        assert.same({ path = wt, created_by_us = true }, load_saved().worktree)
        -- dir 実在 -> head 実ファイルも show 充填も worktree 基準
        -- (bufadd は symlink を解決して buf 名を持つので buffer 名側だけ realpath で
        -- 比較。git へ渡す cwd は記録された worktree path のまま — macOS の
        -- /var -> /private/var 正規化は buf 名側の挙動)
        assert.equals(vim.uv.fs_realpath(vim.fs.joinpath(wt, 'a.lua')), head_buf_name())
        assert.equals(wt, state.git_opts[3].cwd)
      end
    )

    it(
      '記録 true + dir 実在 + 未登録 => add 衝突 -> prune -> 再衝突 -> remove_dir して再 add',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })

        begin_pr {
          function()
            return { code = 0, stdout = 'worktree /elsewhere\n', stderr = '' } -- list: 未登録
          end,
          git_fail 'fatal: already registered\n', -- add1
          git_ok, -- prune
          git_fail 'fatal: already registered\n', -- add2 (dir がまだ在る)
          git_ok, -- add3 (remove_dir 後)
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }

        -- remove_dir が自前 dir を実削除した (add3 はスタブ応答なので dir は再生成されない)。
        assert.is_true(vim.uv.fs_stat(wt) == nil)
        -- list, add1, prune, add2, add3, diff, (open) show
        assert.equals(7, #state.git_calls)
        assert.same({ path = wt, created_by_us = true }, load_saved().worktree)
      end
    )

    it(
      '差分 0 ファイルは「No changes」で開かず、作りたての自前 worktree を掃除して戻る (孤児化防止)',
      function()
        begin_pr {
          git_ok, -- add
          function()
            return diff_ok ''
          end,
          git_ok, -- remove (0 差分掃除)
        }

        assert.same({
          msg = 'review.nvim: no changes (main..feature): nothing to review',
          level = vim.log.levels.INFO,
        }, state.notifications[1])
        assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
        assert.is_nil(load_saved())
        assert.is_nil(session_handler.active())
      end
    )

    -- 0 差分掃除の remove も worktree 登録変更なので直列化契約の対象
    -- (pr-worktree.md「worktree 登録操作の直列化」。「close -> 即 begin」の pin と
    -- 同族で、remove 最中の concurrent add = main--x + main--x1 二重登録の源を
    -- この経路でも reopen しないことを pin する)。
    it(
      '0 差分 remove 最中の begin (pr) は add/diff が lock 待ちで、remove 完了後に再開する',
      function()
        install_git_deferred_remove {
          git_ok, -- add #1
          function()
            return diff_ok ''
          end, -- diff #1: 0 ファイル -> remove (deferred)
          git_ok, -- remove #1 (deferred: placeholder)
          git_ok, -- add #2 (remove 完了後に再開)
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }
        local opts = {
          repo = state.repo,
          id = SLUG,
          mode = 'pr',
          base = 'main',
          head = 'feature',
        }
        session_handler.begin(opts) -- #1: add -> diff 0 -> remove 投入 (未完)

        assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
        assert.is_true(state.deferred ~= nil)

        -- 同一 slug の 2 度目の開始: #1 は 0 差分で save していないので existing
        -- なしで proceed を通り、resolve_worktree で lock を待つ -> git 起動 0 件。
        session_handler.begin(opts)
        assert.equals(3, #state.git_calls)
        assert.is_nil(session_handler.active())

        state.deferred { code = 0, stdout = '', stderr = '' }

        assert.same(add_cmd(), state.git_calls[4])
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[5])
        assert.equals(SLUG, session_handler.active().id)
        assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
      end
    )

    it(
      '記録再利用で 0 差分: remove 成功後、保存 JSON の worktree 記録を nil 化する (実在しない dir を指した記録を残さない)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })
        install_git {
          function()
            return {
              code = 0,
              stdout = 'worktree ' .. state.repo .. '\nworktree ' .. vim.uv.fs_realpath(wt) .. '\n',
              stderr = '',
            }
          end, -- list 登録あり -> 記録を再利用 (add なし)
          function()
            return diff_ok ''
          end,
          git_ok, -- 0 差分掃除の remove 成功
        }
        state.input_answer = 'y' -- 継承確認

        session_handler.begin {
          repo = state.repo,
          id = SLUG,
          mode = 'pr',
          base = 'main',
          head = 'feature',
        }

        assert.same({ 'git', 'worktree', 'remove', wt }, state.git_calls[3])
        assert.is_nil(session_handler.active())
        -- 開始は開かない = 新規 save はしないが、既存 JSON の整合は保つ
        assert.same(
          existing_stub { mode = 'pr', worktree = vim.NIL, updated_at = 4321 },
          load_saved()
        )
      end
    )

    -- issue #14 (a): 差分取得失敗は 0 差分と同じ掃除対象 (作りたてを孤児にしない)
    it(
      '差分取得失敗 (E_REF): 作りたての自前 worktree を掃除して戻る (通知は既存の E_REF 翻訳)',
      function()
        begin_pr {
          git_ok, -- add
          function()
            return {
              code = 128,
              stdout = '',
              stderr = "fatal: bad revision 'main'\nusage: git diff [<options>]\n",
            }
          end, -- diff 失敗 (pr 作成が先行 -> ここで落ちれば孤児化の起点)
          git_ok, -- 掃除の remove
        }

        assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
        assert.same({
          msg = 'review.nvim: cannot resolve the reviewed ref: '
            .. '"main". specify an existing branch/commit '
            .. '(base/head args of start are <Tab>-completable)',
          level = vim.log.levels.WARN,
        }, state.notifications[1])
        assert.is_nil(load_saved())
        assert.is_nil(session_handler.active())
      end
    )

    it(
      '記録再利用 + 差分取得失敗: remove 成功後、保存 JSON の worktree 記録を nil 化する',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })
        install_git {
          function()
            return {
              code = 0,
              stdout = 'worktree ' .. state.repo .. '\nworktree ' .. vim.uv.fs_realpath(wt) .. '\n',
              stderr = '',
            }
          end, -- list 登録あり -> 記録を再利用 (add なし)
          function()
            return { code = 128, stdout = '', stderr = "fatal: bad revision 'main'\n" }
          end, -- diff 失敗
          git_ok, -- 掃除の remove 成功
        }
        state.input_answer = 'y' -- 継承確認

        session_handler.begin {
          repo = state.repo,
          id = SLUG,
          mode = 'pr',
          base = 'main',
          head = 'feature',
        }

        assert.same({ 'git', 'worktree', 'remove', wt }, state.git_calls[3])
        assert.is_nil(session_handler.active())
        assert.same(
          existing_stub { mode = 'pr', worktree = vim.NIL, updated_at = 4321 },
          load_saved()
        )
      end
    )

    it(
      '差分取得失敗の掃除も失敗 (dir 削除不能) + 記録なし: WARN は手动削除案内 (scan 回収不能を «起動 scan が回収» と嘘まらない)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        local locked = io.open(vim.fs.joinpath(wt, 'locked.txt'), 'w')
        locked:write 'x\n'
        locked:close()
        -- dir を r-x: 自前記録の無い dir を remove_dir が消せない (3250 と同じ実権限法)
        vim.fn.system { 'chmod', '555', wt }
        assert.equals(0, vim.v.shell_error)

        begin_pr {
          git_ok, -- add
          git_fail 'fatal: boom\n', -- diff 失敗
          git_fail 'fatal: boom remove\n', -- 掃除の remove 失敗
          git_ok, -- 二段目 prune ok (dir は残る)
        }

        local function find_msg(pat)
          for _, n in ipairs(state.notifications) do
            if n.msg:find(pat, 1, true) ~= nil then
              return n.msg
            end
          end
          return nil
        end
        assert.same(
          'review.nvim: failed to fetch the worktree diff and cleanup '
            .. 'also failed: fatal: boom remove',
          find_msg 'failed to fetch the worktree diff'
        )
        assert.same(
          'review.nvim: failed to delete the worktree dir. dirs without '
            .. 'our own record cannot be reclaimed by the '
            .. 'startup scan; delete '
            .. wt
            .. ' manually',
          find_msg 'startup scan; delete '
        )
        assert.is_nil(load_saved())
        assert.is_nil(find_msg 'startup scan / :Review delete')

        vim.fn.system { 'chmod', '755', wt }
        assert.equals(0, vim.v.shell_error)
      end
    )

    it(
      '0 差分 / 差分取得失敗の掃除は remove spawn 前に worktree 配下 loaded バッファを破棄する (E211 契約・再利用分)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        local file = vim.fs.joinpath(wt, 'a.lua')
        local f = io.open(file, 'w')
        f:write 'line1\n'
        f:close()
        for _, mode in ipairs { 'zero', 'diff-fail' } do
          local buf = vim.fn.bufadd(file)
          vim.fn.bufload(buf)
          assert.equals(1, vim.fn.bufexists(buf), '前提: loaded バッファ (' .. mode .. ')')
          store.save(existing_stub {
            mode = 'pr',
            worktree = { path = wt, created_by_us = true },
          })
          local removed = false
          install_git {
            function()
              return {
                code = 0,
                stdout = 'worktree '
                  .. state.repo
                  .. '\nworktree '
                  .. vim.uv.fs_realpath(wt)
                  .. '\n',
                stderr = '',
              }
            end, -- list 登録あり -> 記録を再利用 (add なし)
            mode == 'zero' and function()
              return diff_ok ''
            end or git_fail "fatal: bad revision 'main'\nusage: git diff [<options>]\n",
            function()
              -- E211 契約の観測点: remove spawn 時点で loaded バッファが消えていること
              -- (remove 自体は git スタブなので、破棄が先行しているかをここで見る)
              assert.equals(
                0,
                vim.fn.bufexists(buf),
                'remove spawn 前に loaded バッファが破棄されていない ('
                  .. mode
                  .. ')'
              )
              removed = true
              return { code = 0, stdout = '', stderr = '' }
            end,
          }
          state.input_answer = 'y'

          session_handler.begin {
            repo = state.repo,
            id = SLUG,
            mode = 'pr',
            base = 'main',
            head = 'feature',
          }

          assert.is_true(removed, 'remove が走らなかった (' .. mode .. ')')
          assert.equals(0, vim.fn.bufexists(buf))
          assert.equals(vim.NIL, load_saved().worktree)
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    )

    it(
      '0 差分掃除は同 path の created_by_us=false legacy 記録を nil 化しない (nil 化対象 = 自前記録のみ)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = false },
        })
        install_git {
          git_ok, -- add (非自前記録は再利用分岐を通らない。作るのは今回の自前分)
          function()
            return diff_ok ''
          end, -- diff 0
          git_ok, -- 0 差分掃除 remove ok (作成分 dir を消す)
        }
        state.input_answer = 'y' -- 継承確認

        session_handler.begin {
          repo = state.repo,
          id = SLUG,
          mode = 'pr',
          base = 'main',
          head = 'feature',
        }

        -- 掃除は走った (remove ok) が、記録の所有が非自前なら nil 化しない
        -- (path 一致だけの gate だと他者/legacy 記録を黙って消す)
        assert.same({ 'git', 'worktree', 'remove', wt }, state.git_calls[3])
        assert.same(
          existing_stub {
            mode = 'pr',
            worktree = { path = wt, created_by_us = false },
            updated_at = 4321,
          },
          load_saved()
        )
      end
    )

    it(
      '0 差分の nil 化 save は save 直前に JSON 存在を再確認する (:Review delete 競合で復活しない)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })
        install_git {
          function()
            return {
              code = 0,
              stdout = 'worktree ' .. state.repo .. '\nworktree ' .. vim.uv.fs_realpath(wt) .. '\n',
              stderr = '',
            }
          end, -- list 登録あり -> 記録を再利用
          function()
            return diff_ok ''
          end, -- diff 0
          function()
            -- remove (重い git I/O) の窓中に :Review delete の finalize が完了する
            -- 競合の模擬: remove 応答時点で JSON は消えている
            assert.equals(true, store.delete(state.repo, SLUG).ok)
            return { code = 0, stdout = '', stderr = '' }
          end,
        }
        state.input_answer = 'y'

        session_handler.begin {
          repo = state.repo,
          id = SLUG,
          mode = 'pr',
          base = 'main',
          head = 'feature',
        }

        -- 掃除側の nil 化 save が削除済み JSON を書き戻して復活させない
        -- (pr-worktree.md «closed の掃除は書き戻さない» と同じ hazard の二重ガード)
        assert.is_nil(load_saved())
      end
    )
  end
)
