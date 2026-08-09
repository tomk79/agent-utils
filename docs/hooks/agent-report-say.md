# `hooks/agent-report-say` 仕様

## 概要

エージェントの1ターン（1回の応答/作業）が終了した際に、作業内容の要約を macOS の `say` コマンドで音声読み上げする。ユーザーレベル（グローバル）フックで、プロジェクト単位の設定や `.env` ファイルには依存しない。

対応先の詳細な連携方式（対応イベント名・トランスクリプト取得方式の制約）は [../architecture.md](../architecture.md) の「対応エージェント」節を参照。

## 起動方法

```
agent-report-say.sh <tool> [outcome]
```

- `<tool>`: 必須の第1引数。エージェント識別子（`claude` / `codex` / `cursor` / `copilot` / `opencode` を想定）。未指定の場合はエラーで終了する。
- `[outcome]`: 任意の第2引数。`done`（既定）または `gaveup`。フォールバックメッセージの文面切り替えに使う。
- 標準入力から、各エージェントの Stop 系フックが渡す JSON ペイロードを読み取る（読み取れなくてもエラーにはしない）。

## 入出力仕様

### 入力（stdin）

JSON オブジェクト。使用するのは以下のフィールドのみ:

- `.last_assistant_message` / `.last_agent_message`（string, 任意）: Codex 等が渡す、直近のアシスタント発話。Codex の場合はトランスクリプト内の `final_answer` を優先し、それが取れない場合に使用する。
- `.transcript_path` または `.transcriptPath`（string, 任意）: `.last_assistant_message` が無い場合に参照するトランスクリプトファイルのパス。

### トランスクリプトからの抽出

Codex の場合:

1. `transcript_path`（または `transcriptPath`）が指すファイルの末尾500行を読む
2. Codex transcript の `response_item` / `event_msg` から `phase == "final_answer"` の assistant message、または `task_complete.last_agent_message` を候補にし、最後の1件を採用する
3. 取得できない場合のみ、hook payload の `.last_assistant_message` / `.last_agent_message` にフォールバックする

Codex 以外、または Codex の専用抽出で取れなかった場合:

1. `transcript_path`（または `transcriptPath`）が指すファイルの末尾200行を読む
2. 各行を JSON としてパースし、`.type == "assistant"`（Claude Code のスキーマ）または `.role == "assistant"`（他エージェントのスキーマ）に該当する行の text 要素を集め、最後の1件を採用する

### 出力

- 標準出力・標準エラーへの通常出力はなし。
- 副作用として macOS の音声合成（`say`）とシステムサウンド再生（`afplay`）を行う。要約器が設定されている場合のみ、要約生成のための外部コマンドまたは HTTP API 呼び出しをバックグラウンドで行う。

### 終了コード

- 常に `0` を返す。これは意図的な仕様であり、読み上げ処理の失敗がエージェント本体の Stop 判定に影響してはならないため。

## 早期リターン条件（no-op になるケース）

以下のいずれかに該当する場合、何もせず `exit 0` する:

1. `uname -s` が `Darwin` でない（macOS 以外）
2. `say` コマンドが存在しない
3. `ENABLE_HOOKS` が `true` でない（スクリプト内ハードコード、現状は常に `true`）
4. `ENABLE_REPORT` が `say` でない（スクリプト内ハードコード、現状は常に `say`）
5. メッセージ抽出（下記）の結果が空 → フォールバックメッセージを読み上げてから `exit 0`

## フォールバックメッセージ

- `outcome` が `done`（既定）: `"${tool} の作業が完了しました。"`
- `outcome` が `gaveup`: `"${tool} の作業が終了しました。テストは失敗したままです。"`

抽出されたメッセージが空の場合、要約処理を行わずこのフォールバックメッセージをそのまま読み上げる。

## 設定

設定ファイルは既定で `~/.config/agent-utils/config.json` を参照する。`AGENT_UTILS_CONFIG_FILE` を指定した場合は、そのパスを優先する。

要約器の選択は以下の優先順位で決まる:

1. `AGENT_UTILS_REPORT_SUMMARIZER_<TOOL>`（例: `AGENT_UTILS_REPORT_SUMMARIZER_CODEX`）
2. `AGENT_UTILS_REPORT_SUMMARIZER`
3. `~/.config/agent-utils/config.json` の `agentReportSay.summarizer.byTool[tool]`
4. `~/.config/agent-utils/config.json` の `agentReportSay.summarizer.default`
5. `none`

設定例:

```json
{
  "version": 1,
  "agentReportSay": {
    "summarizer": {
      "default": "none",
      "byTool": {
        "cursor": "ollama-local"
      },
      "profiles": {
        "none": {
          "type": "none"
        },
        "claude-haiku": {
          "type": "command",
          "command": "claude",
          "args": ["-p", "{prompt}", "--model", "haiku"],
          "timeoutSeconds": 25
        },
        "current-agent": {
          "type": "commandByTool",
          "timeoutSeconds": 25,
          "commands": {
            "claude": {
              "command": "claude",
              "args": ["-p", "{prompt}", "--model", "haiku"]
            },
            "codex": {
              "command": "codex",
              "args": ["exec", "{prompt}"]
            }
          }
        },
        "ollama-local": {
          "type": "httpJson",
          "url": "http://localhost:11434/api/generate",
          "method": "POST",
          "body": {
            "model": "qwen2.5:3b",
            "prompt": "{prompt}",
            "stream": false
          },
          "output": ".response",
          "timeoutSeconds": 25
        }
      }
    }
  }
}
```

サポートする profile type:

- `none`: LLM 要約を行わず、抽出テキストの先頭200文字を読み上げる。
- `command`: `command` と `args` 配列で指定したコマンドを実行する。`args` 内の `{prompt}` は要約プロンプトに置換される。
- `commandByTool`: 呼び出し元ツール名ごとに `commands[tool]` の `command`/`args` を使い分ける。
- `httpJson`: `curl` で JSON API を呼び出し、レスポンスを `output` の jq filter で抽出する。`body` 内の文字列に含まれる `{prompt}` は要約プロンプトに置換される。

## 要約ロジック

抽出したメッセージ（`message`）が取得できた場合:

1. 改行を空白に置換し、先頭200文字に切り詰めたもの（`raw`）を要約の入力・最終フォールバックとして保持する。
2. **再帰防止**: 環境変数 `AGENT_REPORT_SUMMARIZING=1` が既にセットされている場合、これは要約器が同じ Stop フックを再度発火させたケースなので、何もせず `exit 0` する（外側の呼び出しが既に読み上げ済みのため）。
3. 選択された要約器が `none` の場合は、要約せず `raw` をそのまま読み上げて終了する。
4. 要約器が `command` / `commandByTool` / `httpJson` の場合、以下をバックグラウンドで実行する（ジョブは `disown` し、フック自体は即座に返る）:
   - `AGENT_REPORT_SUMMARIZING=1` をエクスポートした上で、設定された要約器を実行する。
   - 要約プロンプトの指示: 「音声で聞いてすぐ理解できる自然な日本語1〜2文に要約する。ファイルパス・変数名・関数名・テーブル名・コードスニペットなどの技術的固有名詞は具体名を出さず意味だけを言い換える。要約文以外は出力しない」
   - 得られた出力を改行除去・トリム・先頭200文字切り詰めした上で `summary` とする。
   - `summary` が空なら `raw` にフォールバックする。
   - `summary`（または `raw`）を読み上げる。

## 読み上げシーケンス（`speak()`）

1. `Glass.aiff` システムサウンドを再生
2. `say "報告します。"`
3. `say "<summary または raw または フォールバックメッセージ>"`
4. `say "以上です。"`
5. `Bottle.aiff` システムサウンドを再生

Cursor では `hooks/lib/say-control.sh` が読み込める場合、2.5秒のデバウンスを行う。`conversation_id` または `transcript_path` からセッションを識別できる場合は strong session key として扱い、同一セッションの先行読み上げ worker を停止する。`workspace_roots[0]` しか無い場合は weak session key として扱う。完了報告では、複数の Stop hook が同一 workspace で連続発火するケースを抑制するため、weak session key でも最新 request id の判定と先行読み上げ停止を行う。同一セッションで同一文面の完了報告が読み上げ完了後30秒以内に再発火した場合は抑制する。

Cursor の完了報告で要約生成を行う場合、session key が取れた時は要約ジョブにも最新 request id を付与する。後続の Stop hook が同一セッションまたは同一 workspace で発火した場合、古い要約ジョブは完走しても読み上げ登録前に破棄する。要約ジョブ自体は kill しない。

## 非機能要件

- 非ブロッキング: 要約生成を含む一連の処理はバックグラウンド化し、呼び出し元の Stop フック処理を待たせてはならない。
- 再帰防止: 要約器が同じフック設定（Stop hook）を経由して自分自身を再発火させても、無限ループや二重読み上げを起こさないこと（`AGENT_REPORT_SUMMARIZING` ガード）。
- フェイルセーフ: 要約器のタイムアウト・失敗時は、必ず `raw`（生メッセージの先頭200文字）にフォールバックして読み上げを継続する。
- 個人情報・機密情報を扱う前提はない。要約プロンプトはファイルパス・識別子等の固有名詞を意図的に音声から排除する仕様である。
