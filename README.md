# review.nvim

Neovim 内で GitHub の Files changed のようにブランチ (git ref) 間の差分をレビューし、コメントを蓄積して **AI エージェントに渡すプロンプト**として出力するプラグイン。

コメントはディスクに永続化されるので、Neovim を間違えて終了しても次回起動後に `:Review` 1 操作で復元できる。ブランチレビューは現在のチェックアウトの**作業ツリー** (未コミット変更を含む) を基準に行い、PR レビューは head を git worktree にチェックアウトして行う (レビュー終了時に worktree はクリーンアップされる)。明示した head が現在の checkout と違うコミットなら、確認付きでそのブランチへ `git switch` を提案し、拒否・実行不能なら `git show` 内容の読み取り専用レビューに縮退する。

## 特徴

- ブランチ間 / コミット間の差分を 2 ペイン表示 (変更ファイル一覧 + unified diff) し、行指定でコメントを作成・編集・削除
- ブランチレビューは head を worktree にしない (現在のチェックアウトの作業ツリーが対象)。`head 省略 = 現在のブランチを自動採用`
- コメント・viewed 状態をセッションとして自動保存。再起動後に `:Review` で復元 (`stdpath("data")` 配下に JSON、Neovim が異常終了しても起動時に検出して通知)
- 保存した差分は自動でレビューに反映。レビュー対象のファイルを保存 (`:w`) すると差分を再取得し、±カウント・コメント位置 (anchor)・プロンプトが直近保存基準で更新される。未保存のバッファ編集は表示にだけ映る
- `:Review pr <番号|URL>` で gh 連携。head を worktree に展開し、`o` でその行の実ファイルを開ける (差分内容と同一の実ファイルなので AI への input としてそのまま読ませられる)
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

`setup()` は省略可能 (既定値で動作 — 起動時のセッション復元通知・worktree 残骸掃除も設定なしで動きます)。設定項目 (`git_bin` / `gh_bin` / `diff_context` / `auto_notify_resume` / `keymaps` / `highlight` / `winbar` / `number`) は `:h review-setup` を参照。

## 使い方

差分をレビューしたいリポジトリで Neovim を起動する:

```vim
:Review start main feature      " main..feature をレビュー (head 明示)
:Review start main              " head 省略 = 現在のブランチを自動採用・保存
                                " (ブランチ名は <Tab> で branches -> tags 順に補完)
                                " 作業ツリー基準なので未コミット変更もレビュー対象
                                " レビュー対象ファイルを :w すると差分を自動再取得
                                " (カウント・プロンプトは保存済み内容基準)
                                " :Review delete の <id> と :Review pr の番号も <Tab> で補完
                                " 同一 refs 組の保存済みセッションがある場合は
                                " 「継承して comments/viewed を引き継ぐか」の [y/N] 確認が出る
:Review pr 42                   " PR #42 を worktree でレビュー
:Review                         " 続きのセッションを復元 (複数あれば選択)
:Review list                    " 保存済みセッション一覧から開く
:Review close                   " 保存して閉じる (pr の worktree はここで掃除される)
:Review delete <id>             " 保存済みセッションを削除 (worktree 掃除含む)
:Review prompt                  " 全コメントのプロンプトをクリップボードへ
:Review prompt lua/foo.lua      " 指定ファイル分のみ
```

### キーマップ

| 場所       | キー                              | 動作                                 |
| ---------- | --------------------------------- | ------------------------------------ |
| diff       | `c` (normal / visual-line)        | コメント作成 (visual は範囲)         |
| diff       | `e` / `d`                         | コメント編集 / 削除 (d は確認の二重押し) |
| diff       | `y`                               | カーソル行コメントのプロンプトを yank |
| diff       | `o`                               | その行の実ファイルを開く             |
| diff       | `q` / `<F1>`                      | セッション終了 / help                |
| diff       | `]d` / `[d`                        | 次 / 前のファイル (一覧順。端は無動作) |
| diff       | `S`                               | 変更一覧へ移動                       |
| diff       | `i`                               | カーソル行のコメント全文を閲覧        |
| 変更一覧   | `<CR>` / `o` / `x` / `/` / `q`    | diff 表示 / 実ファイル / viewed 切替 / 絞り込み |
| セッション一覧 | `<CR>` / `q` / `d`            | 開く / 閉じる / 削除                 |

すべて buffer-local で `setup` の `keymaps` から変更可能 (設定キー名と既定値は `:h review-keymaps`)。例:

```lua
require('review').setup({ keymaps = { diff = { add_comment = 'gc' } } })
```

diff バッファは `wrap=off` + `foldmethod=expr` で、大きい hunk は畳まれた状態で開く。`za` / `zo` / `zR` (Neovim 標準) で展開するか、`o` で実ファイルを開いて読む。hunk 間は `[c` / `]c` (diff filetype 標準)、ファイル間は `]d` / `[d` で移動する。

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

PR セッションは head の worktree で動くため `@` パスは worktree 内の絶対パスになり、エージェントはその場で実ファイルを読める (レビュー中の diff と完全に同一の内容)。ブランチセッションは現在のチェックアウトが対象なので `@` パスはリポジトリ相対で、レビュー中の作業ツリー (保存済み内容) の実ファイルそのものを指す。outdated 認定されたコメント (差分の揺れで位置が特定できないもの) は既定で除外され、diff 上はグレーアウトした `⚠` スレッドで判別できる。本文は対象行の下に全文スレッドで表示される (GitHub の Files changed と同じ向き)。短いスレッドは 10 行で折りたたまれ、全文は `i` の閲覧窓に出る。
review 窓では既定で行番号を隠し、winbar に `base..head · path · +a -d · N comments` を
表示する (GitHub Files changed 風。`setup` の `winbar` / `number` で戻せる)。

## ドキュメント

- 設計: [docs/design/DESIGN.md](docs/design/DESIGN.md) と [docs/design/features/](docs/design/features/)
- 開発・検証: `make check` (test / lint / format / plugin-check) と `make e2e` (実 headless nvim + 実 git のゴールデンパス)。テストに plenary.nvim が必要 (`PLENARY_PATH` で指定)

詳しいキーバインド・書式は `:h review`。

## License

[MIT](LICENSE)
