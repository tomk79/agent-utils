# アーキテクチャ仕様

## 1. ディレクトリ構造

```
<カテゴリ>/<機能名>/
├── <機能名>.sh              # 実行本体（全エージェント共通、引数でエージェント種別を受け取る）
├── meta.json                 # 機能のメタ情報
└── integrations/
    ├── claude-code.json      # Claude Code 向けの導入設定
    ├── codex.json             # Codex CLI 向けの導入設定
    ├── cursor.json            # Cursor CLI 向けの導入設定
    └── copilot.json           # GitHub Copilot CLI 向けの導入設定
hooks/lib/
└── *.sh                       # 複数 hook で共有する補助スクリプト
```

- 現時点でのカテゴリは `hooks/` のみ。
- 機能ディレクトリは `find <REPO_ROOT> -mindepth 3 -maxdepth 3 -name meta.json` で自動検出される（`lib/common.sh` の `discover_features`）。すなわち `<カテゴリ>/<機能名>/meta.json` というパス階層は固定であり、ネストを変えてはならない。
- 1つの `<機能名>.sh` を全エージェントで共有し、対応関係やイベント名の差異は `integrations/*.json` 側に閉じ込める。フックイベントの品質差やペイロード差に起因する最小限のエージェント固有処理は、スクリプト本体または `hooks/lib/` の補助スクリプトに置く。

## 2. `meta.json` スキーマ

```json
{
  "name": "string (必須, 機能ディレクトリ名と一致させる)",
  "description": "string (必須, 一覧表示・選択メニューに使われる説明文)"
}
```

## 3. `integrations/<agent>.json` スキーマ

ファイル名（拡張子を除く）がそのままエージェント識別子として扱われる（`integration_agent_name` = `basename .json`）。

```json
{
  "detect": {
    "configDir": "string (任意, 例: ~/.claude, チルダ展開して存在確認するディレクトリ)",
    "command": "string (任意, 例: claude, PATH 上でのコマンド存在確認)"
  },
  "link": {
    "dir": "string (必須, 機能スクリプトのシンボリックリンクを配置するディレクトリ, チルダ展開される)"
  },
  "settings": "SettingsEntry | SettingsEntry[] (必須, 1つまたは複数)"
}
```

`SettingsEntry`:

```json
{
  "file": "string (必須, 設定ファイルパス, チルダ展開される)",
  "event": "string (必須, hooks オブジェクトのキーとなるイベント名)",
  "entry": "object (必須, hooks[event] 配列に追加/削除される値そのもの)",
  "baseFields": "object (任意, 例: { \"version\": 1 }. 設定ファイル新規作成時に無ければ補う既定フィールド)"
}
```

### 3.1 `detect`（エージェント検出）

`agent_detected()` の仕様:

- `detect.configDir` が指定され、チルダ展開後にディレクトリとして存在する → 検出成功
- 上記が満たされない場合、`detect.command` が指定され、`command -v` で存在する → 検出成功
- どちらも満たさない → 検出失敗（そのマシンでは当該エージェント向けの機能はインストール候補に上がらない）
- `configDir` と `command` はどちらか一方のみの指定も許容される（OR条件で判定）。

### 3.2 `link`（シンボリックリンク配置）

- インストール先パス: `<link.dir展開後>/<機能スクリプトのbasename>`（例: `~/.claude/hooks/agent-notification-say.sh`）
- リンク元: リポジトリ内の `<機能ディレクトリ>/<機能名>.sh` の絶対パス
- `hooks/lib/` が存在する場合、同じ `link.dir` に `agent-utils-lib -> <REPO_ROOT>/hooks/lib` のシンボリックリンクを作成する。既に本リポジトリ管理外の実体がある場合は上書きしない。
- 対象パスが存在せず未使用 → シンボリックリンクを新規作成
- 対象パスが既に本リポジトリが管理する同一シンボリックリンク → 何もしない（冪等）
- 対象パスが別の実体（本リポジトリ管理外のファイル/リンク）として既に存在 → **上書きしない。スキップしてスキップ件数にカウントし、警告を表示する**
- `link.dir` 自体が本リポジトリ内を指す「ディレクトリ全体へのシンボリックリンク」だった場合（旧方式からの移行）、そのリンクを削除してから実ディレクトリを作成する（`prepare_link_dir`）

### 3.3 `settings`（設定ファイルへのフック登録）

- `settings` はオブジェクト1つ、またはオブジェクトの配列のどちらでも指定できる（`list_settings_entries` が正規化する）。1機能・1エージェントで複数イベントにフックを登録する場合は配列を使う（例: Cursor の `agent-notification-say` は `beforeShellExecution` と `beforeMCPExecution` の2エントリ）。
- マージ処理（`settings_merge`）:
  1. 設定ファイルが存在しなければ `{}` として扱う
  2. `baseFields` に指定されたキーが設定ファイルに無ければ追加する（既存の値は上書きしない）
  3. `.hooks[event]` 配列が無ければ空配列として作成する
  4. `entry` が配列内に既に完全一致で存在しなければ追加する（存在すれば何もしない = 冪等）
  5. 書き込みは同一ディレクトリ内の一時ファイルへ出力してから `mv` で置き換える（アトミック更新）
- 削除処理（`settings_remove`）:
  - `.hooks[event]` 配列から `entry` と完全一致する要素を取り除く
  - 設定ファイルが存在しない場合は何もしない
- インストール済み判定（`is_installed`）:
  - シンボリックリンクが本リポジトリ管理下の正しいリンクであること、かつ
  - 全ての `settings` エントリについて、対象ファイルの `.hooks[event]` に `entry` が完全一致で存在すること
  - の両方を満たす場合のみ `true`

## 4. `install.sh` の仕様

```
./install.sh              対話選択メニュー
./install.sh --all        検出された全機能×エージェントの組をインストール
./install.sh <機能名>...  指定した機能名（複数可）のみインストール
```

- 事前条件: `jq` コマンドが必須。無ければエラー終了（exit 1）。
- 候補一覧の構築: 全機能 × 全エージェント統合ファイルの組み合わせのうち、`agent_detected` が真となるものだけを候補とする。
- 候補が0件なら「インストール可能な機能が見つかりませんでした」と表示して正常終了（exit 0）。
- 引数なし実行時は候補を番号付きで一覧表示し（`[installed]` マークで導入済みを明示）、番号をスペース区切りで入力させる。`all` 入力で全選択。空入力は中止（exit 0）。範囲外の番号はエラー（exit 1）。
- `--all` 指定時は候補を全てそのまま選択する。
- 機能名指定時は、候補の中から `basename(feature_dir)` が一致するものを全て選択する（同一機能名で複数エージェントが検出されていれば全部が対象になる）。一致が1件もない機能名はエラー（exit 1）。
- 選択された各組について `install_one` を実行し、シンボリックリンク作成＋設定ファイルへのマージを行う。
- 実行後、`インストール件数` と `スキップ件数` のサマリを表示する。
- 再実行しても安全（冪等）であること。

## 5. `uninstall.sh` の仕様

```
./uninstall.sh              対話選択メニュー（インストール済みのみ表示）
./uninstall.sh --all        インストール済みの全組を削除
./uninstall.sh <機能名>...  指定した機能名（複数可）のみ削除
```

- 事前条件・引数解釈の枠組みは `install.sh` と同様だが、候補は「検出されたエージェント」かつ「`is_installed` が `true`」のものに限る。
- 候補が0件なら「アンインストール対象の機能は見つかりませんでした」と表示して終了。
- `uninstall_one` の処理:
  - シンボリックリンクが本リポジトリ管理下の正しいリンクであれば削除する
  - 削除後、同じ `link.dir` に本リポジトリ管理下の hook シンボリックリンクが残っていなければ、`agent-utils-lib` シンボリックリンクも削除する
  - 別の実体が存在する場合は削除せず警告のみ（本リポジトリ管理外のファイルは触らない）
  - 各 `settings` エントリについて、対象ファイルに entry が存在すれば `settings_remove` で除去する
  - シンボリックリンク削除または設定除去のいずれかを実行した場合のみ「uninstalled」として件数にカウントする。何も対象が無かった場合は「not installed, skip」として扱う
- 実行後、`アンインストール件数` と `スキップ件数` のサマリを表示する。

## 6. 冪等性・安全性の原則

- 本リポジトリが作成したシンボリックリンクと設定エントリのみを操作対象とする。パスや内容が完全一致しない既存ファイルには一切書き込み・削除を行わない。
- 設定ファイルの更新は「一時ファイルに書いてから `mv`」によるアトミック置換とする。
- インストール・アンインストールとも、複数回実行しても結果が変わらないこと（冪等性）を仕様として保証する。

## 7. 対応エージェント

| エージェント識別子 | 検出方法 | シンボリックリンク配置先 | 設定ファイル |
| --- | --- | --- | --- |
| `claude-code` | `~/.claude` ディレクトリ存在 または `claude` コマンド | `~/.claude/hooks/` | `~/.claude/settings.json` |
| `codex` | `~/.codex` ディレクトリ存在 または `codex` コマンド | `~/.codex/hooks/` | `~/.codex/hooks.json` |
| `cursor` | `~/.cursor` ディレクトリ存在 または `cursor-agent` コマンド | `~/.cursor/hooks/` | `~/.cursor/hooks.json` |
| `copilot` | `~/.copilot` ディレクトリ存在 または `copilot` コマンド | `~/.copilot/hooks-scripts/` | `~/.copilot/hooks/agent-utils.json` |

Codex / Cursor / GitHub Copilot は Claude Code ほどフック機構が枯れていないため、以下の制約がある（README.md 記載の内容を仕様として明記する）:

- Codex の `agent-notification-say` / `agent-report-say` は、ユーザーレベルの `~/.codex/hooks.json` に導入する。非 managed command hook は Codex CLI 内の `/hooks` で review/trust されるまで実行されないため、インストーラは trust state を直接編集せず、導入後に手動 trust を案内する。
- Cursor の `agent-notification-say` は、許可プロンプト表示専用の検知イベントが無いため、`beforeShellExecution` / `beforeMCPExecution` に相乗りした「ツール実行前通知」として扱う。「承認してください」という文言は使わない。判定結果は上書きせず常に Cursor の既定挙動に委ねる。
- GitHub Copilot の `agent-notification-say` は、許可プロンプト表示専用の検知イベントが無いため、実際の許可可否判定フック（`permissionRequest`）に相乗りする。判定結果は上書きせず常に既定挙動に委ねる。自動承認されるケースでも音声が鳴ることがあり、Claude Code より通知頻度が高くなる場合がある。
- Cursor / GitHub Copilot の `agent-report-say` は、会話要約に使うトランスクリプトの取得方法・書式がエージェントごとに異なる（Cursor はトランスクリプト機能が有効な場合のみ、Copilot はファイル書式が非公開のためベストエフォート）。要約テキストが取得できない場合は、内容なしの定型メッセージにフォールバックする。
- Cursor の `agent-notification-say` / `agent-report-say` は、同一セッション内で後勝ちの読み上げ制御を行う。`conversation_id` または `transcript_path` が取得できる場合を strong session key とし、デバウンスと同一セッションの先行読み上げ停止を行う。`workspace_roots[0]` しか取得できない場合は weak session key とする。`agent-notification-say` は weak session key ではデバウンスのみ行い、別セッションの通知を止めないため先行読み上げ停止は行わない。`agent-report-say` は Stop hook が同一 workspace で複数回発火するケースを抑えるため、weak session key でも最新 request id の判定と先行読み上げ停止を行う。セッションキーが取得できない場合は制御せず即時読み上げにフォールバックする。

## 8. 依存関係・前提環境

- `jq`: `install.sh` / `uninstall.sh` の必須依存。
- `hooks/` 配下のスクリプトは macOS の `say` / `afplay` コマンドを前提とする。`uname -s` が `Darwin` でない、または `say` コマンドが無い環境ではフック自体が何もせず `exit 0` する（他OSでは無害な no-op）。

## 9. ユーザー設定

フックの実行時設定は、プロジェクト単位の `.env` やリポジトリ直下の未追跡ファイルではなく、ユーザー設定として `~/.config/agent-utils/config.json` に置く。`AGENT_UTILS_CONFIG_FILE` が指定されている場合は、そのパスを優先する。

`agent-report-say` の要約器は既定で `none` とする。要約器の選択は、環境変数 `AGENT_UTILS_REPORT_SUMMARIZER_<TOOL>`、環境変数 `AGENT_UTILS_REPORT_SUMMARIZER`、設定ファイルの `agentReportSay.summarizer.byTool[tool]`、設定ファイルの `agentReportSay.summarizer.default`、`none` の順に解決する。

`agentReportSay.summarizer.profiles` には named profile を定義する。profile type は以下をサポートする:

- `none`: LLM/API を呼ばず、抽出テキストの先頭200文字を読み上げる。
- `command`: `command` と `args` 配列で外部コマンドを実行する。`args` 内の `{prompt}` は要約プロンプトに置換する。
- `commandByTool`: 呼び出し元ツール名ごとに `commands[tool]` の `command`/`args` を使い分ける。
- `httpJson`: `curl` で JSON API を呼び出し、レスポンスを `output` の jq filter で抽出する。`body` 内の `{prompt}` は要約プロンプトに置換する。
- `appleFoundationModels`: macOS 標準のオンデバイス LLM（FoundationModels フレームワーク）で要約する。Swift 製の CLI（`hooks/lib/fm-summarize/main.swift`）を `install.sh` が `hooks/lib/bin/` にビルドし、hook は共有ライブラリ（`agent-utils-lib`）経由でこれを実行する。

設定された要約器の失敗、タイムアウト、未インストール、設定不備は全てフェイルセーフに扱い、`raw`（抽出テキストの先頭200文字）読み上げへフォールバックする。要約器実行時は `AGENT_REPORT_SUMMARIZING=1` を子プロセスに渡し、同じエージェントツールを要約器として使う場合でも再帰発火を抑制する。
