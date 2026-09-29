# pr-comments (PR レビューコメントの GitHub 連携)

- 種別: 機能設計書
- 対象: mode=pr のセッション。branch レビューは従来どおり完全ローカル

## 何を作るか

PR セッション (`:Review pr`) で、GitHub 上に存在するレビューコメント (行スレッド・ファイルレベル・一般 (conversation)) を取り込んで表示し、返信 (`r`)・新規コメント (`c`)・**レビュー submit (`s`)** を GitHub の PR レビュー画面と同じ形で行えるようにする。ローカルと GitHub のコメントは同一のスレッド表示に統合し、submit までは local pending として蓄積して一括で push する。

## 入出力と振る舞い

**取り込み (`begin_session` / `refresh` / `R` の PR フック)** — 3 本の並列 GET (`gh api`):

1. `GET /repos/{o}/{r}/pulls/{n}/comments` — 全レビューコメント (行 + ファイルレベル。`subject_type` で区別)
2. `GET /repos/{o}/{r}/pulls/{n}/reviews` — レビュー一覧 (PENDING review の同定と `gh_state` 判定)
3. `GET /repos/{o}/{r}/issues/{n}/comments` — 一般 (conversation) コメント → `session.general`

行 / ファイルレベルは `comment.from_gh` で Comment へ変換し `thread_at` でスレッドを復元、`gh_id` キーで既存 (ローカル / 前回 fetch) と突合して update / add / remove する (採用 dedup: 同一 gh_id は上書き、消えた gh_id は削除、`in_reply_to` は gh 根の gh_id に張り直す)。一般コメントは `GeneralComment` として `session.general` に持つ。

**表示** — 行スレッドは従来の行下スレッド (作者接頭辞 `[<login>]`、pending は `⚠`)。ファイルレベルコメントは head 窓の 1 行目上に `[file] <path>` 見出しの箱で表示 (outdated 集約の多重化は積み上げ)。一般コメントは `review://pr-chat/<session-id>` バッファ (コメント一覧と同じ最下部全幅) に 1 コメント = 作者行 + 本文行で表示。

**返信 (`r` / commentlist `r` / prchat `r`)** — 既存スレッドへの返信は `in_reply_to` = スレッドの根 (gh 根は gh_id、ローカル根は id) を持って local pending として追加。GitHub 上では同じスレッド (reply) に残る。

**submit (`s` / `:Review submit` / commentlist `s` / prchat `s`)** — event (Comment / Approve / Request changes) 選択 + 任意サマリ本文を経て pending を push:

1. **新規の行コメント**は `POST /pulls/{n}/reviews` に `{event, body, comments:[{path, line, body}]}` で **1 レビューとして submit** (GitHub の PR レビュー画面と同じ形。個別 POST はコメントごとに別レビュー化してしまう)
2. **ファイルレベルコメントと返信**は `POST /pulls/{n}/comments` (`in_reply_to`) で個別に POST (review comments 配列は `in_reply_to` / `subject_type=file` を載せられない)
3. **一般コメント**は `POST /issues/{n}/comments`

push 後に `GET /pulls/{n}/reviews/{id}/comments` で投げたコメントの `gh_id` を (path+line+body 照合で) 突合してセッションへ反映し、pending マーカーを外して保存する。失敗は WARN で pending を保持 (再試行可)。

**API の落とし穴 (実測)**:

- `gh api -f/-F` のフォーム値はすべて文字列になり、整数フィールド (`line` / `in_reply_to`) が GitHub に 422 で弾かれる → JSON body を一時ファイル (`vim.fn.tempname()`) に書いて `gh api --input <file>` で送る (`gh.run_api_json`)
- `PUT /pulls/{n}/reviews/{id}` は本文編集のみで submit しない ("event is not a permitted key")。submit は上記の `POST /pulls/{n}/reviews` (comments 配列付き) か、docs 通り `POST /pulls/{n}/reviews/{id}/events` が正
- ファイルレベルコメントの API 表現は `line: 1` + `subject_type: "file"` (`from_gh` は `subject_type` を先に判定)

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| gh api (repo 解決 / list / create / run_api_json) | adapters | `lua/review/git/gh.lua` |
| Comment / GeneralComment 拡張・from_gh・thread 復元 | core | `lua/review/core/comment.lua` |
| 取り込み・突合・表示マーカー | handlers / ui | `lua/review/handlers/pr_comments.lua` / `ui/commentmarks.lua` |
| 返信 entry | handlers | `lua/review/handlers/comments.lua` / `comments_list.lua` |
| submit フロー | handlers | `lua/review/handlers/submit.lua` |
| 一般コメント UI | handlers / ui | `lua/review/handlers/pr_chat.lua` / `ui/prchat.lua` |

## 非スコープ

- 他ユーザーのコメントの編集・削除
- コメント一括の GitHub 状態への同期 (fetch は 3 GET の上書きであり、GitHub 側で消えたコメントは削除しない — 採番・表示安定のため `gh_id` の追加のみ)
- 一般コメントの編集・削除
- fork / base 側への書き込み
