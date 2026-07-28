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

現状は Claude Code (`~/.claude/`) のみに対応しています。各機能ディレクトリの `integrations/` 配下に、対応エージェントごとの設定ファイルが追加されていく想定です。

## 提供している機能

| 機能 | 説明 |
| --- | --- |
| `hooks/agent-report-say` | ターン終了時に、作業内容の要約を音声で読み上げる |
| `hooks/agent-notification-say` | ツール実行の許可待ち(permission prompt)を音声で通知する |
