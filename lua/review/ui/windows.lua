-- ui/windows: レビュー専有 tabpage の 3 窓レイアウト (docs/design/features/
-- diff-review.md「レイアウト (専有 tabpage 3 窓)」「窓 role は id ではなく内容 +
-- 窓変数から導く」「review tab の消滅経路」/ DESIGN.md「窓の所有」「UI 形態」)。
-- 担当は窓の配置・窓 opts・窓変数 (役割 gate / winbar)・tab 開閉まで。
-- バッファの中身 (git show 充填 / :edit / 実ファイル解決) とキーマップは
-- handlers/session + ui/scratchwin + ui/keygate の責務 (ここはbufを張るだけ)。
--
-- 開通順序の契約: vsplit の新窓は現窓のバッファを継承するため、窓を先にすべて
-- 作ってから set_buf する (AGENTS「先に vsplit」)。位置は splitright に依存せず
-- wincmd L で右端へ寄せる。窓 role は内容 + 窓変数から導く (UX review F1 の真因
-- だった id 実体判定の drift を構造で消す)。
local config = require 'review.config'
local ui_chrome = require 'review.ui.chrome'

local M = {}

-- state = { tab, panel_win, base_win, head_win, on_tab_closed, closing }
local st = nil

local autocmd_id = nil

local TAB_GROUP = vim.api.nvim_create_augroup('review_windows', { clear = true })

local function valid_win(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

--- 窓 diff ペアの opts (base/head 窓ローカル)。`diffopt` は world option なので
--- 触らない (DESIGN「既知の制約」)。wrap=off は virt_text 干渉回避 (同左)。
--- foldcolumn は 0.10 (number) / 0.13 (string) で API 型が変わるため、両版で
--- 安定な :setl (窓ローカル) 経路で一括設定する。
local function apply_pair_opts(w)
  vim.api.nvim_win_call(w, function()
    vim.cmd 'setl diff scrollbind cursorbind foldmethod=diff foldlevel=0 foldcolumn=1 nowrap'
  end)
end

-- binary 注釈窓・削除告知窓など窓 diff に参加しない窓の退避。`:diffoff` は
-- foldmethod を元へ戻さない (既知の制約) ので manual を明示し、さらに `zE` で
-- diff 由来の保存 fold を解消する — manual だと残 fold がそのまま動き続ける
-- ため、退避の検証可能形 foldclosed()==-1 (DESIGN「既知の制約」窓 diff) を
-- 保証する。告知 1 行窓が fold で跳ぶ事故も同時に防ぐ。
local function apply_diffoff(w)
  vim.api.nvim_win_call(w, function()
    vim.cmd 'setl nodiff noscrollbind nocursorbind foldmethod=manual foldcolumn=0 nowrap'
    vim.cmd 'normal! zE'
  end)
end

local function release_autocmd()
  if autocmd_id ~= nil then
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
    autocmd_id = nil
  end
end

--- tab 作成時に tcd (tab-local cwd)。効果の対象は LSP server プロセスの spawn
--- cwd と相対パス解決ツール (DESIGN 決定表「LSP 連携」。root_dir はバッファパス
--- 起点の遡上で決まり tcd は関与しない)。
--- 存在しない dir への tcd は E344 を投げるため pcall で吸収する (窓配置は
--- 成立させ、後から :Review start/復元の流れで正常な dir に張り直せる。
--- 開通を中断すると tab だけ残してレビュー不能になる)。
local function tcd(dir)
  if dir == nil then
    return
  end
  pcall(vim.cmd, 'tcd ' .. vim.fn.fnameescape(dir))
end

function M.open(opts)
  if st ~= nil then
    error('windows.open: review tab already open (close it first)', 2)
  end
  vim.cmd 'tabnew'
  local tab = vim.api.nvim_get_current_tabpage()
  tcd(opts.dir)
  -- panel になる窓 (tabnew 直後の [No Name]) から vsplit + wincmd L を 2 回。
  -- 新窓が右端へ積まれるので 1 回目が base、2 回目が head になり、
  -- 「窓を作ってから set_buf」の順序契約が全経路で守られる。
  local panel_win = vim.api.nvim_get_current_win()
  vim.cmd 'vsplit'
  vim.cmd 'wincmd L'
  local base_win = vim.api.nvim_get_current_win()
  vim.cmd 'vsplit'
  vim.cmd 'wincmd L'
  local head_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_config(panel_win, { width = config.get().panel_width })
  vim.wo[panel_win].winfixwidth = true
  -- base/head 窓 opts は bind 側 (buf を張るとき) に適用する。開通直後の
  -- 空 [No Name] 共有窓に foldmethod=diff を当てると、その後の set_buf で
  -- diff fold の再計算が効かず foldclosed() が永久に -1 になる (0.13 実測。
  -- 窓 diff の fold は diffopt/foldcontext 基準で計算されるため、内容確定後の
  -- 適用が必要)。

  st = {
    tab = tab,
    panel_win = panel_win,
    base_win = base_win,
    head_win = head_win,
    on_tab_closed = opts.on_tab_closed,
    closing = false,
  }

  -- review tab がユーザー操作 (:tabclose / :tabonly 等) で消えた検知。
  -- close() 側は closing フラグで区別する (q = close の掃除はここで走らせない)。
  -- 帰属判定は nvim_list_tabpages() への現存で行う。is_valid は TabClosed 発火
  -- 時点の handle 失効タイミングがバージョン間で違い、0.10.0 では閉じた直後の
  -- review tab が true を返って「別の tab が閉じた」と誤判定し発火しない (issue #26
  -- 実測: 0.10.0 is_valid=true / list 現存=false、0.13 は both false)。
  release_autocmd()
  autocmd_id = vim.api.nvim_create_autocmd('TabClosed', {
    group = TAB_GROUP,
    callback = function()
      local current = st
      if current == nil or current.closing then
        return
      end
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        if t == current.tab then
          return -- 閉じられたのは別の tab (review tab は現存)
        end
      end
      st = nil
      release_autocmd()
      -- 窓と一緒に消えない global 状態 (winbar 式) を元へ戻す
      ui_chrome.restore_global()
      if current.on_tab_closed ~= nil then
        current.on_tab_closed()
      end
    end,
  })

  vim.api.nvim_set_current_win(head_win)
  return st
end

function M.state()
  return st
end

--- テスト・異常経路用の状態だけ落とす低レベル reset (窓は閉じない)。
function M.reset()
  st = nil
  release_autocmd()
end

function M.win(role)
  if st == nil then
    return nil
  end
  local w = st[role .. '_win']
  return valid_win(w) and w or nil
end

--- 窓の役割を内容 + 窓変数から導く。
---   panel = 表示 buf が review://sidebar/... (一覧)
---   base  = 窓変数 gate (w:review_base_gate==win) と表示 buf 指紋が一致
---   head  = 窓変数 gate (w:review_key_gate==win) と表示 buf 指紋が一致
--- scratch 系は review_meta からも導ける (DESIGN「窓の所有」: buffer 作成元で
--- 決めつけず導く。実ファイル窓は gate のみ = ユーザー窓では不成立)。
function M.role_of(win)
  if not valid_win(win) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match '^review://sidebar/' then
    return 'panel'
  end
  if vim.w[win].review_key_gate == win and vim.w[win].review_gate_buf == buf then
    return 'head'
  end
  if vim.w[win].review_base_gate == win and vim.w[win].review_base_buf == buf then
    return 'base'
  end
  local meta = vim.b[buf].review_meta or {}
  if meta.kind == 'scratch' then
    -- 告知系 (deleted/binary) はどの窓に現れてもコメント不可側 (head 窓枠と同じ
    -- 扱いで keygate 側が meta から WARN を選ぶ)。base scratch は base 側。
    if meta.scratch == 'base' then
      return 'base'
    end
    return 'head'
  end
  return nil
end

--- 一覧窓 (commentlist buffer を表示する窓) か。ensure_pair の anchor に選ばない:
--- 最下部全幅の一覧から分割すると base/head が一覧の行内に積まれる (issue #37)。
local function is_commentlist_win(w)
  if not valid_win(w) then
    return false
  end
  local meta = vim.b[vim.api.nvim_win_get_buf(w)].review_meta or {}
  return meta.kind == 'commentlist'
end

--- base/head 窓のペアを確保する。どちらかの窓が消えていれば panel (または
--- 専有 tab 内の生き窓) を基準に再建する。内容が差し替わっただけの
--- drift は窓そのものが生きているので set_buf の張り直しで復旧する (再建不要)。
local function ensure_pair()
  local base_ok = valid_win(st.base_win) and vim.api.nvim_win_get_tabpage(st.base_win) == st.tab
  local head_ok = valid_win(st.head_win) and vim.api.nvim_win_get_tabpage(st.head_win) == st.tab
  if base_ok and head_ok then
    return
  end
  for _, role in ipairs { 'base', 'head' } do
    local w = st[role .. '_win']
    if valid_win(w) and w ~= st.panel_win then
      pcall(vim.api.nvim_win_close, w, true)
    end
    st[role .. '_win'] = nil
  end
  local anchor = valid_win(st.panel_win)
      and vim.api.nvim_win_get_tabpage(st.panel_win) == st.tab
      and st.panel_win
    or nil
  if anchor == nil then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(st.tab)) do
      if not is_commentlist_win(w) then
        anchor = w
        break
      end
    end
  end
  if anchor == nil then
    -- 終端: tab 内に一覧窓しか残っていない (panel 閉 + base/head 消滅)。ここで
    -- nil を返すと bind が nil 窓への窓変数書込で生の error で死に、base_win /
    -- head_win = nil が state に残留して以後の窓再建が恒久不能になる。旧実装と
    -- 同じく一覧窓を最終 fallback の anchor に再建する (レイアウトは崩れ得るが
    -- 再建とレビュー続行は成立する — issue #37 review r1 finding 1)。
    anchor = vim.api.nvim_tabpage_list_wins(st.tab)[1]
  end
  if anchor == nil then
    return
  end
  vim.api.nvim_set_current_win(anchor)
  -- rightbelow vsplit の 2 回で上段に base -> head の順に積む。旧実装の
  -- `wincmd L` は一覧 (最下部全幅) があると再建窓を画面の全高の右端列へ
  -- 出し、一覧の全幅を崩すため使わない (issue #37)。
  vim.cmd 'rightbelow vsplit'
  st.base_win = vim.api.nvim_get_current_win()
  vim.cmd 'rightbelow vsplit'
  st.head_win = vim.api.nvim_get_current_win()
  apply_pair_opts(st.base_win)
  apply_pair_opts(st.head_win)
end

--- base / head 窓にバッファを張り、役割 gate 窓変数を更新する。
--- opts = { diffoff? = 'both' (binary 注釈・no-changes の共有窓 / 追加 (base 0 行
---          scratch) ペア / 削除告知ペア — 窓 diff ペアを作らない窓),
---          head_kind? = 'real' (head が実ファイル = gate の内容指紋は bufnr) }。
--- 呼び出し側 (handlers/session.open_file) が中身の充填を終えた後に呼ぶ。
--- 前回張り付いていた別 buf の窓変数 (stale gate) は set_buf 前に消し、
--- gate が「窓変数 + 今の表示内容」の同時一致でしか通らないことを保つ。
function M.bind(base_buf, head_buf, opts)
  if st == nil then
    error('windows.bind: review tab not open', 2)
  end
  opts = opts or {}
  ensure_pair()
  local bw, hw = st.base_win, st.head_win
  -- 窓再利用で張り返しても前回 buf は hidden で diff group に残積し、group は
  -- 全体で 8 buffer 上限 (E96 «Cannot diff more than 8 buffers»)。set_buf 前に
  -- 現窓の buf を group から刈る (今回張る buf と同一なら diffoff しない =
  -- 同一ファイルの再 bind で窓 diff が解けるのを防ぐ)。
  local function detach_prev_diff(w, keep)
    if not valid_win(w) then
      return
    end
    local cur = vim.api.nvim_win_get_buf(w)
    if cur ~= keep and vim.api.nvim_buf_is_valid(cur) then
      vim.api.nvim_win_call(w, function()
        pcall(vim.cmd, 'diffoff')
      end)
    end
  end
  detach_prev_diff(bw, base_buf)
  detach_prev_diff(hw, head_buf)
  vim.w[bw].review_base_gate = nil
  vim.w[bw].review_base_buf = nil
  vim.w[hw].review_key_gate = nil
  vim.w[hw].review_gate_buf = nil

  vim.api.nvim_win_set_buf(bw, base_buf)
  vim.api.nvim_win_set_buf(hw, head_buf)
  if opts.diffoff ~= nil then
    -- 窓 diff ペアを作らない窓 (binary 注釈共有・no-changes・追加 (0 行 base) ペア・
    -- 削除告知ペア): 両窓を退避させる
    apply_diffoff(bw)
    apply_diffoff(hw)
  else
    apply_pair_opts(bw)
    apply_pair_opts(hw)
  end
  vim.w[bw].review_base_gate = bw
  vim.w[bw].review_base_buf = base_buf
  vim.w[hw].review_key_gate = hw
  vim.w[hw].review_gate_buf = head_buf
  vim.api.nvim_set_current_win(hw)
  return bw, hw
end

--- panel 窓に sidebar buf を張るrender 側を載せる (窓が不要になる前兆 drift も
--- ここで正規化: 別窓へ sidebar 内容が引っ越したらその窓を panel として覚える)。
function M.set_panel_buf(buf)
  if st == nil then
    return
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(st.tab)) do
    if vim.api.nvim_win_get_buf(w) == buf and w ~= st.base_win and w ~= st.head_win then
      st.panel_win = w
      break
    end
  end
  local pw = M.win 'panel'
  if pw == nil then
    return
  end
  vim.api.nvim_win_set_buf(pw, buf)
end

--- `<leader>b`: panel 窓を閉じる (tab とレビュー窓は残る。view state で save なし)。
function M.hide_panel()
  if st == nil then
    return
  end
  local pw = M.win 'panel'
  if pw ~= nil then
    pcall(vim.api.nvim_win_close, pw, true)
  end
  st.panel_win = nil
end

--- panel 再建 (focus `<leader>e` / toggle)。上段の左へ `leftabove vsplit` で寄せる。
--- `wincmd H` は使わない: H は panel を画面の全高で最左へ寄せるため、一覧
--- (最下部全幅) がある状態で再建すると一覧の全幅が L 字に崩れる (issue #37)。
--- leftabove なら splitright の値によらず panel は上段の左に入る。
function M.show_panel(buf)
  if st == nil then
    return
  end
  local pw = M.win 'panel'
  if pw ~= nil then
    st.panel_win = pw
    if buf ~= nil then
      M.set_panel_buf(buf)
    end
    vim.api.nvim_set_current_win(pw)
    return pw
  end
  local anchor = M.win 'base' or M.win 'head'
  if anchor == nil then
    -- 同族の終端 (panel 閉 + base/head 消滅、tab に一覧窓しか残っていない):
    -- nil のまま nvim_set_current_win すると生の error で <leader>e が死ぬため、
    -- tab に残る窓を anchor にする (ensure_pair の最終 fallback と同じ方針)。
    anchor = vim.api.nvim_tabpage_list_wins(st.tab)[1]
  end
  if anchor == nil then
    return nil
  end
  vim.api.nvim_set_current_win(anchor)
  vim.cmd 'leftabove vsplit'
  st.panel_win = vim.api.nvim_get_current_win()
  pw = st.panel_win
  vim.api.nvim_win_set_config(pw, { width = config.get().panel_width })
  vim.wo[pw].winfixwidth = true
  if buf ~= nil then
    M.set_panel_buf(buf)
  end
  return pw
end

--- コメント一覧 (横断) の新規窓をレビュー tab の最下部に全幅で作る
--- (`botright split` + 高さ `config.comment_list_height` + winfixheight)。
--- 押した窓や splitright に位置が依存しない (comment-list「操作」/ issue #37)。
--- 分割元の窓 diff opts を継承するため apply_diffoff で退避する (base/head から
--- 分割しても一覧が diff group に入らない)。バッファの render は呼び出し側
--- (handlers/comments_list) の責務。`:Review comments` は tab gate を持たないため、
--- 呼び出し元の tab に依らず review tab へ切替えてから分割する。
function M.open_comment_list()
  if st == nil then
    error('windows.open_comment_list: review tab not open', 2)
  end
  if vim.api.nvim_get_current_tabpage() ~= st.tab then
    vim.api.nvim_set_current_tabpage(st.tab)
  end
  vim.cmd(('botright %dsplit'):format(config.get().comment_list_height))
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].winfixheight = true
  apply_diffoff(w)
  return w
end

--- 専有 tab 内に作らなかったはずの空窓が残っていた場合の回収 (float 破片 /
--- error 窓等)。条件は厳しく: 無名・buftype 空・modifiable・中身 0/空行・
--- review meta なし・役割窓以外 (AGENTS「空窓回収」から 3 窓化)。
function M.sweep()
  if st == nil then
    return
  end
  local keep = {
    [st.panel_win] = true,
    [st.base_win] = true,
    [st.head_win] = true,
  }
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(st.tab)) do
    if vim.api.nvim_win_is_valid(w) and not keep[w] then
      local b = vim.api.nvim_win_get_buf(w)
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      local empty = #lines == 0 or (#lines == 1 and lines[1] == '')
      if
        vim.api.nvim_buf_get_name(b) == ''
        and vim.bo[b].buftype == ''
        and vim.bo[b].modifiable
        and empty
        and vim.b[b].review_meta == nil
        and vim.w[w].review_key_gate == nil
      then
        pcall(vim.api.nvim_win_close, w, false)
      end
    end
  end
end

--- `q` / `:Review close` からの窓の閉じ方: tab 消滅経路 (TabClosed hook) と
--- 区別するため closing を立ててから tab を閉じる (close の掃除は callers 側)。
function M.close()
  if st == nil then
    return
  end
  local current = st
  st = nil
  release_autocmd()
  current.closing = true
  if vim.api.nvim_tabpage_is_valid(current.tab) then
    pcall(vim.api.nvim_set_current_tabpage, current.tab)
    pcall(vim.cmd, 'tabclose!')
  end
  -- tab と一緒に消えない global 状態 (winbar 式) を元へ戻す
  ui_chrome.restore_global()
end

return M
