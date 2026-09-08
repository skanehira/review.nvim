-- scripts/plugin_check.lua — headless で plugin/review.lua が読み込まれ
-- :Review が定義されること、:help review が到達できること、未知サブコマンドが
-- WARN + usage 1 行になることを確認する。成否は print + os.exit で返し、
-- 例外は stderr に出さない (scripts/plugin-check.sh が stderr 空を判定する)。

local function out(line)
  io.stdout:write(line .. '\n')
  io.stdout:flush()
end

local function fail(msg)
  out('plugin-check FAILED: ' .. msg)
  os.exit(1)
end

local repo = vim.fn.getcwd()
vim.opt.runtimepath:append(repo)
vim.cmd 'runtime! plugin/review.lua'

if vim.fn.exists ':Review' ~= 2 then
  fail ':Review が定義されていない'
end

-- 未知サブコマンド: プラグイン経由の通知経路 (spy で検証、画面出力に依存しない)。
local notified = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  table.insert(notified, { msg = msg, level = level })
end
vim.cmd 'Review definitely-unknown-sub'
vim.notify = real_notify

local usage = 'usage: :Review [start <base> [head] | pr <number|url> | list | '
  .. 'close | delete <id> | prompt [file]]'
if #notified ~= 1 then
  fail('通知が ' .. #notified .. ' 件 (期待 1 件)')
end
if notified[1].msg ~= 'review.nvim: unknown subcommand: definitely-unknown-sub. ' .. usage then
  fail('通知メッセージ不一致: ' .. notified[1].msg)
end
if notified[1].level ~= vim.log.levels.WARN then
  fail '通知レベルが WARN でない'
end

-- :help review — doc/review.txt がテンポラリ rtp にコピーして helptags を作り
-- 到達を確認する (リポジトリの doc/ を汚染しない)。
local rtp_copy = vim.fn.tempname()
if vim.fn.mkdir(rtp_copy .. '/doc', 'p') == 0 then
  fail('テンポラリ rtp が作れない: ' .. rtp_copy)
end
local lines = vim.fn.readfile(repo .. '/doc/review.txt')
if vim.fn.writefile(lines, rtp_copy .. '/doc/review.txt') ~= 0 then
  fail 'doc/review.txt がコピーできない'
end
vim.opt.runtimepath:append(rtp_copy)
-- FileType autocmd (help ftplugin の treesitter 等) は検証対象の外。
-- ユーザーマシンの parser ABI 汚染で stderr が汚れて DoD 判定が
-- 誤失敗するのを防ぎ、文書到達のみ検証する。
local ei_save = vim.o.eventignore
vim.o.eventignore = 'FileType'
vim.cmd('helptags ' .. vim.fn.fnameescape(rtp_copy .. '/doc'))
vim.cmd 'help review'
local bufname = vim.api.nvim_buf_get_name(0)
vim.cmd 'bwipeout!'
vim.o.eventignore = ei_save
if not bufname:match 'review%.txt$' then
  fail(':help review が review.txt に到達できない (bufname=' .. bufname .. ')')
end
vim.fn.delete(rtp_copy, 'rf')

out 'plugin-check OK'
os.exit(0)
