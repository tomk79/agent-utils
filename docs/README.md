# agent-utils 仕様書

このディレクトリは `agent-utils` リポジトリが提供する機能の仕様を固定した文書群です。実装を変更する際は、まず本仕様書との差分を確認し、仕様変更を伴う場合は本仕様書もあわせて更新してください。

## 構成

| 文書 | 内容 |
| --- | --- |
| [architecture.md](./architecture.md) | リポジトリ全体の設計。機能ディレクトリの構造、`install.sh`/`uninstall.sh`/`lib/common.sh` の仕様、`meta.json` と `integrations/*.json` のスキーマ |
| [hooks/agent-notification-say.md](./hooks/agent-notification-say.md) | `agent-notification-say` フックの仕様 |
| [hooks/agent-report-say.md](./hooks/agent-report-say.md) | `agent-report-say` フックの仕様 |

## リポジトリの目的

AIコーディングエージェント（Claude Code / Codex CLI / Cursor CLI / GitHub Copilot CLI）向けのフック・ユーティリティ集。各機能は `<カテゴリ>/<機能名>/` ディレクトリに自己完結した形で格納され、対応するエージェントごとに個別にインストール／アンインストールできる。
