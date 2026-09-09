-- slug / repo-hash / セッションファイルのパス配置
-- (docs/design/features/persistence-restore.md「実装の配置」、
-- DESIGN.md「データスキーマ」「アーキテクチャと技術選定」永続化の行)。
-- ファイルシステムにアクセスしない純粋関数のみ。stdpath("data") の解決だけ
-- 外界なので _set_data_dir で注入する (テストは tmpdir を注入し本物を汚さない)。

-- sha1 実装に LuaJIT の bit モジュールを使う。Neovim 標準 API に sha1 は無く
-- (vim.fn にあるのは sha256 のみ)、repo-hash の契約は sha1 先頭 16 桁なので
-- ハッシュ算法を私自換しないこと (DESIGN.md「既知の制約」)。
local bit = require 'bit'

local M = {}

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, tobit = bit.lshift, bit.rshift, bit.tobit

local function rotl32(x, n)
  return bor(lshift(x, n), rshift(x, 32 - n))
end

-- LuaJIT の string.format('%x') は負の int32 を 64bit 符号拡張で 16 桁出力する。
-- %08x に渡す直前に非負の double (0..2^32-1) へ正規化する。
local function u32(x)
  x = band(x, 0xffffffff)
  if x < 0 then
    x = x + 0x100000000
  end
  return x
end

local SHA_K = { 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xca62c1d6 }

-- 入力文字列の sha1 を小文字 16 進 40 桁で返す (RFC 3174)。
-- 入力は repo パス程度の短さを前提とする (1 文字ずつバイト展開する)。
function M.sha1_hex(s)
  local ml = #s
  -- 0x80 + 0 埋め + 64bit BE ビット長で 64 バイトブロックへ整列させる。
  local pad_len = (56 - (ml + 1) % 64) % 64
  local bits_lo = tobit(ml * 8)
  local bits_hi = tobit(math.floor(ml / 0x20000000)) -- 前提: 入力は 2^59 バイト未満
  local tail = string.char(
    band(rshift(bits_hi, 24), 0xff),
    band(rshift(bits_hi, 16), 0xff),
    band(rshift(bits_hi, 8), 0xff),
    band(bits_hi, 0xff),
    band(rshift(bits_lo, 24), 0xff),
    band(rshift(bits_lo, 16), 0xff),
    band(rshift(bits_lo, 8), 0xff),
    band(bits_lo, 0xff)
  )
  local msg = s .. '\128' .. string.rep('\0', pad_len) .. tail

  local h0, h1, h2, h3, h4 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
  local w = {}
  for block = 0, #msg - 1, 64 do
    for i = 0, 15 do
      local p = block + i * 4 + 1
      local b1, b2, b3, b4 = msg:byte(p, p + 3)
      w[i] = tobit(b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4)
    end
    for i = 16, 79 do
      w[i] = rotl32(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bor(band(b, c), band(bnot(b), d))
        k = SHA_K[1]
      elseif i < 40 then
        f = bxor(b, c, d)
        k = SHA_K[2]
      elseif i < 60 then
        f = bor(band(b, c), band(b, d), band(c, d))
        k = SHA_K[3]
      else
        f = bxor(b, c, d)
        k = SHA_K[4]
      end
      a, b, c, d, e = band(rotl32(a, 5) + f + e + k + w[i], 0xffffffff), a, rotl32(b, 30), c, d
    end
    h0 = band(h0 + a, 0xffffffff)
    h1 = band(h1 + b, 0xffffffff)
    h2 = band(h2 + c, 0xffffffff)
    h3 = band(h3 + d, 0xffffffff)
    h4 = band(h4 + e, 0xffffffff)
  end
  return ('%08x%08x%08x%08x%08x'):format(u32(h0), u32(h1), u32(h2), u32(h3), u32(h4))
end

-- repo 固有ディレクトリ名: sha1(repo) の先頭 16 桁
-- (DESIGN.md「アーキテクチャと技術選定」永続化の行)。
function M.repo_hash(repo_path)
  return (M.sha1_hex(repo_path):sub(1, 16))
end

-- データスキーマ id の規則: [A-Za-z0-9._-] 以外の文字を _ に置換する。
local function sanitize_ref(ref)
  return (ref:gsub('[^%w%._%-]', '_'))
end

-- branch セッションの slug: main..feature → main--feature。
-- refs 組の連結区切りも _ 変換も単射とは限らない (稀な ref 名由来の衝突は
-- slug_conflict で検出し、新規作成を拒否して既存を案内する —
-- persistence-restore.md「エッジケースの決定」)。
function M.branch_slug(base, head)
  return sanitize_ref(base) .. '--' .. sanitize_ref(head)
end

-- PR セッションの slug: pr-<number>。branch slug は必ず -- を含むため
-- 両モード間で衝突しない。
function M.pr_slug(number)
  return 'pr-' .. number
end

-- slug 下の既存セッション (store.load の返し。無ければ nil) と、
-- 新規開始しようとする refs 組を比べる。一意性は refs 組が決めるので、
-- 既存の refs 組と 1 つでも違えば衝突 (同一なら継承で衝突ではない)。
function M.slug_conflict(existing, base, head)
  if existing == nil then
    return false
  end
  return existing.base ~= base or existing.head ~= head
end

-- stdpath("data") 相当のルート。nil なら呼び出し時に本物を解決する
-- (setup 順に依存しない)。テストは tmpdir を注入する。
local data_dir_override = nil

function M._set_data_dir(dir)
  data_dir_override = dir
end

function M.sessions_dir()
  local data_dir = data_dir_override or vim.fn.stdpath 'data'
  return vim.fs.joinpath(data_dir, 'review.nvim', 'sessions')
end

-- worktree 配置の親。sessions と兄弟にし、repo-hash 下へ slug を置く
-- (pr-worktree.md「worktree 作成判断」の <slug> を repo 単位に分離し、
-- 別 repo の同一 slug がパス衝突で互いを阻害しないようにする)。
function M.worktrees_root()
  local data_dir = data_dir_override or vim.fn.stdpath 'data'
  return vim.fs.joinpath(data_dir, 'review.nvim', 'worktrees')
end

-- 1 セッションの worktree path: <worktrees>/<repo-hash>/<slug>。
function M.worktree_path(repo_path, slug)
  return vim.fs.joinpath(M.worktrees_root(), M.repo_hash(repo_path), slug)
end

-- 1 repo のセッション置き場: <sessions>/<sha1(repo) 先頭 16 桁>。
function M.repo_dir(repo_path)
  return vim.fs.joinpath(M.sessions_dir(), M.repo_hash(repo_path))
end

function M.session_file(repo_path, slug)
  return vim.fs.joinpath(M.repo_dir(repo_path), slug .. '.json')
end

-- 破損 / version 不一致ファイルの退避先。自動削除しない (片付けは手動)。
function M.corrupt_file(repo_path, slug)
  return M.session_file(repo_path, slug) .. '.corrupt'
end

return M
