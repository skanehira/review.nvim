# review.nvim

Neovim 内で GitHub の Files changed のようにブランチ (git ref) 間の差分をレビューし、コメントを蓄積して **AI エージェントに渡すプロンプト**として出力するプラグイン。

コメントはディスクに永続化されるので、Neovim を間違えて終了しても次回起動後に `:Review` 1 操作で復元できる。PR を指定した場合は head を git worktree にチェックアウトし、**実ファイルを読みながら**レビューできる (レビュー終了時に worktree はクリーンアップされる)。

## 特徴

- ブランチ間 / コミット間の差分を 2 ペイン表示 (変更ファイル一覧 + unified diff) し、行指定でコメントを作成・編集・削除
- コメント・viewed 状態をセッションとして自動保存。再起動後に `:Review` で復元 (`stdpath("data")` 配下に JSON、Neovim が異常終了しても起動時に検出して通知)
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
  config = function()
    require('review').setup {}
  end,
}
```

`setup()` は省略可能 (既定値で動作)。設定項目 (`git_bin` / `gh_bin` / `diff_context` / `auto_notify_resume` / `keymaps` / `highlight`) は `:h review-setup` を参照。

## 使い方

差分をレビューしたいリポジトリで Neovim を起動する:

```vim
:Review start main feature      " main..feature の差分を開く (head 省略時は補完付きで選択)
                                " base / head は <Tab> で branches -> tags 順に補完
:Review pr 42                   " PR #42 を worktree でレビュー
:Review                         " 続きのセッションを復元 (複数あれば選択)
:Review list                    " 保存済みセッション一覧から開く
:Review close                   " 保存して閉じる (worktree はここで掃除される)
:Review delete <id>             " 保存済みセッションを削除 (worktree 掃除含む)
:Review prompt                  " 全コメントのプロンプトをクリップボードへ
:Review prompt lua/foo.lua      " 指定ファイル分のみ
```

### キーマップ

| 場所       | キー                              | 動作                                 |
| ---------- | --------------------------------- | ------------------------------------ |
| diff       | `c` (normal / visual-line)        | コメント作成 (visual は範囲)         |
| diff       | `e` / `d`                         | カーソル行のコメント編集 / 削除      |
| diff       | `y`                               | カーソル行コメントのプロンプトを yank |
| diff       | `o`                               | その行の実ファイルを開く             |
| diff       | `q` / `<F1>`                      | セッション終了 / help                |
| 変更一覧   | `<CR>` / `o` / `x` / `q`          | diff 表示 / 実ファイル / viewed 切替 |
| セッション一覧 | `<CR>` / `q`                  | 開く / 閉じる                        |

すべて buffer-local で `setup` の `keymaps` から変更可能。

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

worktree を使うセッション (PR など) では `@` パスは worktree 内の絶対パスになるため、エージェントはその場で実ファイルを読める。outdated 認定されたコメント (差分の揺れで位置が特定できないもの) は既定で除外される。

## ドキュメント

- 設計: [docs/design/DESIGN.md](docs/design/DESIGN.md) と [docs/design/features/](docs/design/features/)
- 開発・検証: `make check` (test / lint / format / plugin-check) と `make e2e` (実 headless nvim + 実 git のゴールデンパス)。テストに plenary.nvim が必要 (`PLENARY_PATH` で指定)

詳しいキーバインド・書式は `:h review`。

## License

[MIT](LICENSE)
