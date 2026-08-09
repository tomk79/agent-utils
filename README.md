# agent-utils

AIコーディングエージェント（Claude Code など）向けのフックやユーティリティ集。各機能は `<カテゴリ>/<機能名>/` ディレクトリにまとまっており、対応するエージェントごとに個別のインストール/アンインストールができます。

## 導入方法

```sh
git clone https://github.com/tomk79/agent-utils.git
cd agent-utils
./install.sh
```

引数なしで実行すると、このマシンで検出されたエージェント向けに導入可能な機能が一覧表示され、対話的に選択してインストールできます。

```sh
./install.sh --all            # 導入可能なものをすべてインストール
./install.sh agent-report-say # 機能名を指定してインストール
```

アンインストールも同様です。

```sh
./uninstall.sh                # インストール済みの機能を対話的に選択して削除
./uninstall.sh --all          # インストール済みのものをすべて削除
```

再実行しても安全です（冪等）。既にインストール済みの項目は変更されず、`~/.claude/hooks` などにこのリポジトリと無関係なファイルが既にある場合はスキップされ、上書き・削除はされません。

### 依存関係

- `jq` が必須です（`brew install jq`）
- `hooks/` 配下のスクリプトは macOS の `say`/`afplay` コマンドを前提にしています。他OSではフック自体が何もせず終了します

### 対応エージェント

現状、以下のエージェントに対応しています。各機能ディレクトリの `integrations/` 配下に、対応エージェントごとの設定ファイルが追加されていく想定です。

- Claude Code (`~/.claude/`)
- Codex CLI (`~/.codex/`, `codex` コマンド)
- Cursor CLI (`~/.cursor/`, `cursor-agent` コマンド)
- GitHub Copilot CLI (`~/.copilot/`, `copilot` コマンド)

Codex / Cursor / GitHub Copilot は Claude Code ほど枯れていないフック機構のため、下記の制約があります。

- Codex のフックは `~/.codex/hooks.json` にユーザーレベルで導入しますが、Codex CLI 内で `/hooks` を開いて内容を確認し、trust するまで実行されません。
- Cursor の `agent-notification-say` は、許可プロンプト表示専用イベントが無いため、`beforeShellExecution`/`beforeMCPExecution` に相乗りした「ツール実行前通知」として読み上げます。「承認してください」とは読み上げません。
- GitHub Copilot の `agent-notification-say` は、許可プロンプトの表示だけを検知する専用イベントが無く、実際に許可の可否を判定する `permissionRequest` に相乗りしています。判定結果は上書きせず常に各エージェントの既定の挙動に委ねますが、自動承認されるケースでも音声が鳴ることがあり、Claude Code より通知頻度が高くなる場合があります。
- Cursor のツール実行前通知は、`conversation_id` または `transcript_path` が取れる場合のみ、同一セッションの先行読み上げを停止します。完了報告は Stop hook が同一 workspace で複数回発火するケースを抑えるため、`workspace_roots[0]` しか取れない場合も最新の報告だけを優先します。
- Cursor / GitHub Copilot の `agent-report-say` は、会話内容の要約に使うトランスクリプトの取得方法・書式がエージェントによって異なります（Cursor はトランスクリプト機能が有効な場合のみ、Copilot はファイル書式が非公開のためベストエフォート）。要約テキストが取得できない場合は、内容なしの定型メッセージにフォールバックします。

## 提供している機能

| 機能 | 説明 |
| --- | --- |
| `hooks/agent-report-say` | ターン終了時に、作業内容の要約を音声で読み上げる |
| `hooks/agent-notification-say` | ツール実行の許可待ち(permission prompt)を音声で通知する |
