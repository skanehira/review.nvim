# review.nvim

English: [README.md](README.md) · **日本語** (this file)

GitHub の Files changed 風に、ブランチ (git ref) 間の差分と PR の差分を Neovim 内でレビューし、コメントを蓄積して **AI エージェントに渡すプロンプト**として出力するプラグイン。

差分は専有 tabpage の 3 窓 (file panel │ base │ head) で開き、head 窓は実ファイルなので編集も LSP も効いたままレビューできる。追加ファイルは base が無いため base 窓を閉じ、head のみを全幅表示する。差分は窓ローカル `'winhl'` で GitHub 風に着色される (diffview.nvim の `enhanced_diff_hl` と同方式): 行内の変更語は head = 緑 / base = 赤、旧側にしか無い行 (削除) は削除色、filler 行は dim。コメントは自動的にディスクへ永続化され、Neovim を再起動しても `:Review` 1 操作で復元する。ランタイム依存ゼロ (Neovim 標準 API のみ)。

## 必要要件

| 要件              | 対象              |
| ----------------- | ----------------- |
| Neovim >= 0.10    | 共通              |
| git               | 共通              |
| GitHub CLI (`gh`) | `:Review pr` のみ |

## インストール

```lua
{
  'skanehira/review.nvim',
  lazy = false,
  opts = {},
}
```

`setup()` は省略可能 (既定値でそのまま動く)。キーや見た目を変えたいときだけ追加する。設定項目は `:h review-setup`。

マネージャを使わず `rtp` に足す場合は `:helptags <repo>/doc` を 1 回実行すると `:h review` が引ける。

## 使ってみる

`main` を基準に、現在のブランチをレビューするまでを 4 手順で示す:

**1. 差分を開く**

```vim
:Review start main
```

`main..現在のブランチ` の差分が 3 窓 (追加ファイルは base 窓を閉じて head のみ) で開く。対象は現在のチェックアウトの作業ツリーなので、未コミット変更もレビューに含まれる。head を明示する場合は `:Review start main feature` (main に対して feature をレビュー)。PR は `:Review pr 42`。

**2. コメントを書く**

`<Tab>` / `<S-Tab>` でファイルを移動し、変更行で `c` を押して本文を入力する (visual-line で行を選択すれば範囲コメント)。確定したコメントは対象行の下にスレッド箱として表示され、`e` で編集、`d` の二重押しで削除する (同じ行に複数コメントがある場合 — スレッドの根と返信など — は番号プロンプトで対象を選ぶとその場で削除される)。コメントは確定のたびに保存される。

head 窓で `:w` すると差分が再取得され、±カウント・コメント位置・プロンプトが保存済みの内容に更新される。

**3. (PR) GitHub のレビュー画面と同じようにコメント・返信・submit**

PR セッション (`:Review pr`) では既存のレビューコメントを取り込んでスレッドに
表示する (各コメントは作者の接頭辞、未 submit は ⚠ マーカー。ファイルレベル
コメントはファイル 1 行目上に箱で表示し、PR 会話は `p` / `:Review pr-chat` で
開く)。スレッド上で `r` を押すと返信でき (GitHub 上では同じスレッドに残る)、
`c` で新規コメント。これらは local pending として蓄積され、`s` /
`:Review submit` で push して event (Comment / Approve / Request changes) +
任意のサマリ本文でレビューを確定する (`:h review-pr-comments`)。

**4. プロンプトを取り出して AI に渡す**

`:Review prompt` で集めたコメントが整形され、クリップボードにコピーされる (クリップボードが使えない環境では `"0` レジスタ)。コピーが成功すると «copied %d comments to the clipboard» とメッセージが出る (`y` でも同じ):

```text
Review the changes in main..feature. Please address the comments below.

@lua/review/diff.lua#L42-L48
この行番号計算は core/diff の変換ロジックを使って

@lua/review/init.lua#L10
setup は冪等にしたい
```

これをそのまま AI エージェントに貼り付ける。`@path#L<行>` はレビュー中の実ファイルを指すので、エージェントはパスを辿って該当箇所を読める。1 件だけコピーしたい場合はレビュー窓でそのコメントの行に移動して `y`、特定ファイルだけなら `:Review prompt lua/foo.lua`。outdated のコメント (差分の揺れで位置を特定できなくなったもの) は既定の出力から除外される (`:h review-sessions`)。

コピー後に不要になったコメントは `:Review clear` (またはレビュー窓 / コメント一覧で `D` 2 回) で全件削除できる。AI に渡した後の残骸掃除用で、outdated も含めて全部消える。コピー後の自動削除はしない — ミスコピ時に再度コピーできる余地を残すためで、削除は常に明示操作 + 確認 (コマンドは `[y/N]`、キーは arming 二重押し) を挟む。二重押しの途中取消は `<Esc>` でもよい (2 秒待ち不要)。

**5. 閉じる**

`q` (または `:Review close`) でコメントを保存して閉じる。`:Review pr` で展開した worktree は残す (closed セッションは素早く再開でき、未コミット編集ごと同じ worktree を再利用する)。worktree を消すにはセッションを削除する: `:Review delete {id}` (または `:Review list` の `d`)。削除は確認付きで、worktree に未コミット変更があると `--force` を確認する。

## キーマップ

上記の流れで触る最小限だけ:

| 場所       | キー                      | 動作                                                  |
| ---------- | ------------------------- | ----------------------------------------------------- |
| レビュー窓 | `c` (visual-line で範囲)  | コメント作成 (head 窓のみ)                            |
| レビュー窓 | `e` / `d`                 | 編集 / 削除 (d は確認の二重押し)                      |
| レビュー窓 | `D`                       | 全コメント一括削除 (二重押し。`:Review clear` と同じ) |
| レビュー窓 | `<Esc>`                   | d / D の二重押し (arming) を解除            |
| レビュー窓 | `<Tab>` / `<S-Tab>`       | 次 / 前のファイル                                     |
| レビュー窓 | `[c` / `]c`               | このファイルの前 / 次のコメントへジャンプ (head 窓のみ) |
| レビュー窓 | `<leader>e` / `<leader>b` | file panel へ移動 / 表示トグル                        |
| レビュー窓 | `<leader>c`               | 全ファイル横断のコメント一覧                          |
| レビュー窓 | `r`                       | カーソル行のスレッドへ返信 (head 窓のみ)              |
| レビュー窓 | `s`                       | レビュー submit (pending push + event。PR セッションのみ) |
| レビュー窓 | `p`                       | PR 会話 (一般コメント) を開く (PR セッションのみ)     |
| レビュー窓 | `q`                       | 保存してセッションを閉じる                            |
| レビュー窓 | `<F1>` / `g?`             | その窓で効くキーの help float                         |

すべてのキーは buffer-local で、窓によって効くキーが違う。各窓の完全な一覧と既定値は `:h review-keymaps` (レビュー中に `<F1>` / `g?` と押すと、その窓で効くキーの一覧が help float に出る)。既定値の変更は `setup` の `keymaps` から:

```lua
require('review').setup({ keymaps = { diff = { add_comment = 'gc' } } })
```

fold (`za` / `zo` / `zR`) は Neovim 標準のキーのままで、レビュー側からはマップしていない。レビュー窓では `[c` / `]c` をコメント移動 (前 / 次のコメント) に割り当てている (標準の hunk 移動は自分の窓ではそのまま使える)。レビュー窓のキーマップはキーを押した時点の窓の role を照合して発火するため、自分の窓で同じ実ファイルを見ていてもレビュー操作は誤発火しない。

## コマンド

| コマンド                        | 動作                                                        |
| ------------------------------- | ----------------------------------------------------------- |
| `:Review start {base} [{head}]` | ブランチレビュー開始 (head 省略 = 現在のブランチを自動採用) |
| `:Review pr {番号\|URL}`        | PR レビュー開始 (head を worktree に展開)                   |
| `:Review`                       | 続きのセッションを復元 (open 状態のみ)                      |
| `:Review list`                  | 保存済みセッション一覧から開く                              |
| `:Review comments`              | コメント横断一覧を開く (`<leader>c` と同じ)                 |
| `:Review pr-chat`               | PR 会話 (一般コメント) を開く (`p` と同じ)                  |
| `:Review submit`                | レビュー submit (pending push + event。`s` と同じ)          |
| `:Review close`                 | 保存して閉じる                                              |
| `:Review delete {id}`           | 保存済みセッションを削除 (worktree 掃除含む)                |
| `:Review prompt [file]`         | プロンプトをクリップボードへ (ファイル指定可)               |
| `:Review clear`                 | コメントを全件削除 ([y/N] 確認。`D` 2 回と同じ)             |

`start` の ref 名、`pr` の番号、`delete` の id は `<Tab>` で補完できる。Neovim の異常終了時の復旧や `q` と `:tabclose` の挙動の違いなど、セッション管理の詳細は `:h review-sessions`。

## 設計上のふるまい (抜粋)

- 明示した head が現在の checkout と違うコミットを指す場合、確認付きでそのブランチへの `git switch` を提案する。拒否された場合や switch できない場合は、読み取り専用レビューに縮退する (`:h review-usage`)
- 差分の揺れで位置を特定できなくなったコメントは outdated として可視化される (スレッドの id 接頭辞が警告色、head 窓 1 行目に集約表示) (`:h review-sessions`)
- winbar に `base..head · path · +a -d · N comments` を表示し、行番号は既定で隠す。どちらも `setup` の `winbar` / `number` で切り替えられる (`:h review-display`)

## ドキュメント

- ヘルプの目次: `:h review` (english) / 日本語版は `:h review_ja` (`set helplang=ja` で `:h review-*` が日本語版に解決される)
- 公開 Lua API: `:h review-api`
- 設計: [docs/design/DESIGN.md](docs/design/DESIGN.md) と [docs/design/features/](docs/design/features/)
- 開発・検証: `make check` (test / lint / format / plugin-check) と `make e2e` (実 headless nvim + 実 git のゴールデンパス)。テストに plenary.nvim が必要 (`PLENARY_PATH` で指定)

## License

[MIT](LICENSE)
