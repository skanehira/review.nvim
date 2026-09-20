# review.nvim

Neovim 内で GitHub の Files changed のようにブランチ (git ref) 間の差分をレビューし、コメントを蓄積して **AI エージェントに渡すプロンプト**として出力するプラグイン。

コメントはディスクに永続化されるので、Neovim を間違えて終了しても次回起動後に `:Review` 1 操作で復元できる。ブランチレビューは現在のチェックアウトの**作業ツリー** (未コミット変更を含む) を基準に行い、PR レビューは head を git worktree にチェックアウトして行う (レビュー終了時に worktree はクリーンアップされる)。明示した head が現在の checkout と違うコミットなら、確認付きでそのブランチへ `git switch` を提案し、拒否・実行不能なら `git show` 内容の読み取り専用レビューに縮退する。

## 特徴

- 差分は専有 tabpage の 3 窓 (file panel │ base │ head) の**窓 diff** で確認。head 窓は実ファイルなので編集も LSP も効いたままレビューできる。file panel はトグル可
- ブランチレビューは head を worktree にしない (現在のチェックアウトの作業ツリーが対象)。`head 省略 = 現在のブランチを自動採用`
- コメント・レビュー完了マーク (`[✓]`、panel の `x` で手動トグル) をセッションとして自動保存。再起動後に `:Review` で復元 (`stdpath("data")` 配下に JSON、Neovim が異常終了しても起動時に検出して通知)
- 保存した差分は自動でレビューに反映。レビュー対象ファイルを保存 (`:w`。head 窓でもユーザー窓でも可、縮退 scratch は対象外) すると差分を再取得し、±カウント・コメント位置 (anchor)・プロンプトが直近保存基準で更新され、窓 diff も保存時に再計算される。未保存のバッファ編集は表示にだけ映る
- `:Review pr <番号|URL>` で gh 連携。head を worktree に展開し、レビュー tab はその worktree に tcd される (head 窓 = worktree 内の実ファイル。レビュー終了時に worktree はクリーンアップされる)
- コメントを `@path#L<行>` 形式のプロンプトとしてクリップボード / レジスタへコピー
- ランタイム依存ゼロ (Neovim 標準 API のみ)

## 必要要件

| 要件               | 対象              |
| ------------------ | ----------------- |
| Neovim >= 0.10     | 共通              |
| git                | 共通              |
| GitHub CLI (`gh`)  | `:Review pr` のみ |

## インストール

```lua
{
  'skanehira/review.nvim',
  lazy = false,
  build = ':helptags ALL', -- doc/tags 生成 (プラグインマネージャが自動の場合でも保険)
  config = function()
    require('review').setup {}
  end,
}
```

マネージャを使わず `rtp` に直接足す場合は、clone 先の `doc/` に対して `:helptags <repo>/doc` を 1 回実行すると `:h review` が引けるようになります。

`setup()` は省略可能 (既定値で動作 — 起動時のセッション復元通知・worktree 残骸掃除も設定なしで動きます)。設定項目 (`git_bin` / `gh_bin` / `diff_context` / `auto_notify_resume` / `panel_width` / `comment_list_height` / `keymaps` / `highlight` / `winbar` / `number`) は `:h review-setup` を参照。

## 使い方

差分をレビューしたいリポジトリで Neovim を起動する:

```vim
:Review start main feature      " main..feature をレビュー (head 明示)
:Review start main              " head 省略 = 現在のブランチを自動採用・保存
                                " (ブランチ名は <Tab> で branches -> tags 順に補完)
                                " 作業ツリー基準なので未コミット変更もレビュー対象
                                " head 窓で :w すると差分を自動再取得
                                " (カウント・プロンプトは保存済み内容基準)
                                " :Review delete の <id> と :Review pr の番号も <Tab> で補完
                                " 同一 refs 組の保存済みセッションがある場合は
                                " 「継承して comments/完了マークを引き継ぐか」の [y/N] 確認が出る (y/n + <Enter>)
:Review pr 42                   " PR #42 を worktree でレビュー
:Review                         " 続きのセッションを復元 (複数あれば選択)
:Review list                    " 保存済みセッション一覧から開く
:Review comments                " 横断コメント一覧を開く (<leader>c と同じ)
:Review close                   " 保存して閉じる (pr の worktree はここで掃除される)
:Review delete <id>             " 保存済みセッションを削除 (worktree 掃除含む)
:Review prompt                  " 全コメントのプロンプトをクリップボードへ
:Review prompt lua/foo.lua      " 指定ファイル分のみ
```

### キーマップ

| 場所                | キー                              | 動作                                 |
| ------------------- | --------------------------------- | ------------------------------------ |
| レビュー窓 (head/base) | `c` (normal / visual-line)     | コメント作成 (visual は範囲。head 窓のみ) |
| レビュー窓          | `e` / `d`                         | コメント編集 / 削除 (d は確認の二重押し) |
| レビュー窓          | `y`                               | カーソル行コメントのプロンプトを yank |
| レビュー窓          | `q` / `<F1>` / `g?`               | セッション終了 / help (g? も同じ)    |
| レビュー窓          | `<Tab>` / `<S-Tab>`               | 次 / 前のファイル (file panel の表示順 = ツリー上→下。端は無動作) |
| レビュー窓          | `[F` / `]F`                       | 最初 / 最後のファイル |
| レビュー窓          | `R`                               | 差分を再取得 (リフレッシュ)          |
| レビュー窓          | `<leader>e`                       | file panel へ移動                    |
| レビュー窓          | `<leader>b`                       | file panel 表示トグル                |
| レビュー窓          | `<leader>c`                       | コメント一覧 (横断) を開く           |
| レビュー窓          | `i`                               | カーソル行のコメント全文を閲覧        |
| file panel          | `<CR>` / `o` / `l`              | entry を開く (ファイル行 = head/base に開く・カーソルは file panel に残る、dir 行 = 折り畳み) |
| file panel          | `<Tab>` / `<S-Tab>` / `[F` / `]F` | 次 / 前 / 最初 / 最後のファイル (focus は file panel に残る。レビュー窓から押すと head 窓に残る) |
| file panel          | `R`                               | 差分を再取得 (レビュー窓と同じ)      |
| file panel          | `i`                               | list (フルパス 1 行) ⇄ tree 表示切替 |
| file panel          | `x` / `/` / `q`                   | 完了マーク [✓] 切替 / 絞り込み / 終了 |
| file panel          | `<F1>` / `g?`                     | help (レビュー窓と同じ)              |
| file panel          | `<leader>c`                       | コメント一覧 (横断) を開く           |
| コメント一覧        | `<CR>` / `d` / `e` / `y` / `q`    | コメント位置へジャンプ / 削除 (二重押し) / 編集 / プロンプト yank / 一覧を閉じる |
| セッション一覧      | `<CR>` / `q` / `d`                | 開く / 閉じる / 削除                 |

すべて buffer-local で `setup` の `keymaps` から変更可能 (設定キー名と既定値は `:h review-keymaps`)。レビュー窓のキーは押した時点の窓 role を照合して発火するので、ユーザーが自分の窓で同じ実ファイルを見ていてもレビュー操作は誤発火しません (gate を通らない窓では 1 キーストロークが built-in 動作に戻ります)。例:

```lua
require('review').setup({ keymaps = { diff = { add_comment = 'gc' } } })
```

head/base の 2 窓は Neovim 標準の窓 diff (`foldmethod=diff`) で、変更行は `DiffAdd` / `DiffDelete` 系の標準 highlight で色分けされます。追加・削除ファイルは窓 diff ペアを作らないため**両窓とも窓 diff を無効化**し (head/base とも素の色)、種別は head 窓 winbar のマークで判別できます。hunk 間は `[c` / `]c` (標準)、fold は `za` / `zo` / `zR` (標準) で、レビュー側からのキーマップはありません。ファイル間は `<Tab>` / `<S-Tab>` (次 / 前) と `[F` / `]F` (最初 / 最後)、変更一覧への focus は `<leader>e`、一覧のトグルは `<leader>b`、差分の再取得は `R` です (diffview に近い導線)。

file panel は既定でフォルダツリー表示です。単一 child の dir 連鎖は `a/b/c/` と連結され、dir 行の status は配下の集約 (全部同一記号ならそのまま、混在は `*`)。`<CR>` / `o` / `l` を dir 行で押すと折り畳み、ファイル行で押すと head/base 窓に開きます。開いてもカーソルと focus は file panel に残るので、一覧を辿りながら diff を見比べられます (panel から押した `<Tab>` / `<S-Tab>` / `[F` / `]F` も focus を file panel に残します。diff 窓へ移るのはレビュー窓起点の移動キーと、標準の `<C-w>l` / `<C-w>w`)。フラットなフルパス一覧が見たければ `i` で list 表示へ切替 (絞り込み・折り畳みと並ぶ view state で、セッションには保存されません)。ファイルを移動で開くと panel のカーソルがその行に追従し、選択行がハイライトされます (相互ハイライト)。nvim-web-devicons が入っていればファイルアイコンが自動で出ます (無くてもテキスト表示のまま。ランタイム依存にはなりません)。

`<leader>c` (または `:Review comments`) でセッションの全コメントをファイル横断の一覧として開きます。一覧はレビュー tab の**最下部に全幅** (高さは既定 10 行、`comment_list_height` で変更可) で開かれ、どの窓・どの tab から押しても位置は変わりません。1 行 = 1 コメントで `path:line [id] 本文 1 行目` (60 文字を超える本文は `…`、outdated は末尾に `⚠ outdated`)。並びは file panel と同じツリー表示順で、折り畳み・list 表示は反映せず、絞り込み `/` は反映します。`<CR>` でそのコメント位置へジャンプ (実ファイルまたは縮退 head を開いて記録行へ移動。outdated は INFO、binary/削除の告知表示・現在の差分に無いファイルは WARN)、`q` で閉じます。既に開いていれば再分割せずその窓へ focus し、内容は最新に更新されます。

`c` / `e` で開くコメント入力ウィンドウは、本文入力中 (insert) は **`<CR>` = 改行**、`q` などで Normal に戻ったあと **`<CR>` = 確定** して閉じる。本文があるときは `q` では閉じず (誤って入力を捨てないため)、続けて `q` を押したときだけ破棄して閉じる。`<C-y>` は insert 中の確定、`<Esc>` は Normal に戻るだけで窓は閉じない。操作はウィンドウのタイトルと `<F1>` の help にも表示される。

### AI エージェントへの渡し方

`:Review prompt` でクリップボード (無い環境では `"0` レジスタ) に入る:

```text
Review the changes in main..feature. Please address the comments below.

@lua/review/diff.lua#L42-L48
この行番号計算は core/diff の変換ロジックを使って

@lua/review/init.lua#L10
setup は冪等にしたい
```

PR セッションは head の worktree で動くため `@` パスは worktree 内の絶対パスになり、エージェントはその場で実ファイルを読める (レビュー中の diff と完全に同一の内容)。ブランチセッションは現在のチェックアウトが対象なので `@` パスはリポジトリ相対で、レビュー中の作業ツリー (保存済み内容) の実ファイルそのものを指す。outdated 認定されたコメント (差分の揺れで位置が特定できないもの) は既定で除外され、diff 上はスレッド id 接頭辞 (`[c1]`) が警告色で表示されることで判別できる (`⚠` グリフや本文のグレーアウトはしない)。本文は範囲の最終行の下に罫線の箱で囲んだスレッドで表示され (GitHub の Files changed と同じ向き。箱の幅は head 窓に追従し、本文は箱の内側で折り返される)、短いスレッドは 10 行で折りたたまれ、全文は markdown filetype の `i` 閲覧窓に出る。
review 窓では既定で行番号を隠し、winbar に `base..head · path · +a -d · N comments` を
表示する (GitHub Files changed 風。追加ファイルは末尾に ` · new file`、削除は
`· deleted` を表示。`setup` の `winbar` / `number` で戻せる)。表示は
review バーの窓がある tab に限られ、他の tab では winbar の行は確保されない。

## ドキュメント

- 設計: [docs/design/DESIGN.md](docs/design/DESIGN.md) と [docs/design/features/](docs/design/features/)
- 開発・検証: `make check` (test / lint / format / plugin-check) と `make e2e` (実 headless nvim + 実 git のゴールデンパス)。テストに plenary.nvim が必要 (`PLENARY_PATH` で指定)

詳しいキーバインド・書式は `:h review`。

## License

[MIT](LICENSE)
