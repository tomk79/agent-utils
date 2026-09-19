// agent-utils-fm-summarize: runs a prompt read from stdin through the macOS
// on-device language model (Apple Intelligence, FoundationModels framework)
// and prints the response. Used by agent-report-say's `appleFoundationModels`
// summarizer profile.
//
// Usage:
//   printf '%s' "$prompt" | agent-utils-fm-summarize [--timeout SEC] [--max-input-chars N]
//
// Exits 0 with the response on stdout, or 1 on any failure (model unavailable,
// empty input, timeout, context overflow, guardrail refusal, ...) so the caller
// can fall back to the raw text.
import Foundation
import FoundationModels

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agent-utils-fm-summarize: \(message)\n".utf8))
    exit(1)
}

var timeoutSeconds: Double = 25
var maxInputChars = 2500

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--timeout":
        guard let value = argIterator.next().flatMap(Double.init), value > 0 else {
            fail("--timeout requires a positive number")
        }
        timeoutSeconds = value
    case "--max-input-chars":
        guard let value = argIterator.next().flatMap(Int.init), value > 0 else {
            fail("--max-input-chars requires a positive integer")
        }
        maxInputChars = value
    default:
        fail("unknown argument: \(arg)")
    }
}

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard !input.isEmpty else { fail("empty prompt") }
// The context window is ~4096 tokens. The instruction sits at the head of the
// prompt, so cutting the tail keeps it intact.
let prompt = String(input.prefix(maxInputChars))

// Summarizing arbitrary agent output is a content transformation, which the
// default guardrails refuse more often than needed.
let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
guard case .available = model.availability else {
    fail("model unavailable: \(model.availability)")
}

DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
    fail("timed out after \(timeoutSeconds)s")
}

Task {
    do {
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: prompt)
        print(response.content)
        exit(0)
    } catch {
        fail("\(error)")
    }
}

dispatchMain()
