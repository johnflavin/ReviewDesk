import Foundation

/// Scope presets say what to look for; voice presets say how to write it.
enum PresetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case scope, voice

    var id: String { rawValue }
    var title: String { self == .scope ? "Scope" : "Voice" }
}

struct Preset: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: PresetKind
    var name: String
    var text: String
    var builtIn = false
}

enum Presets {
    static let defaultScopeID = "builtin.scope.standard"
    static let defaultVoiceID = "builtin.voice.colleague"

    static let builtIn: [Preset] = [
        Preset(id: defaultScopeID, kind: .scope, name: "Standard", text: """
            Focus on what matters for merging this change:
            - Correctness: logic errors, unhandled edge cases, off-by-one errors, null or empty handling, broken error paths, race conditions and resource leaks.
            - Behavior changes the description doesn't mention, and breaking changes to public APIs, configuration, data formats or migrations.
            - Security: injection, missing authorization checks, unsafe handling of user input or secrets.
            - Tests: changed behavior with no test, or tests that don't check what they claim to.
            Skip formatting and style that a linter or formatter would catch. Raise design or readability only when it's likely to cause bugs or real maintenance cost.
            """, builtIn: true),
        Preset(id: "builtin.scope.bugs", kind: .scope, name: "Bugs only", text: """
            Only report things that are wrong: code that will fail, give incorrect results, lose data or open a security hole under inputs or conditions that can actually occur. For each one, say what goes wrong and when.
            Don't comment on style, naming, design, test coverage or possible improvements. If you find nothing wrong, say so.
            """, builtIn: true),
        Preset(id: "builtin.scope.thorough", kind: .scope, name: "Thorough", text: """
            Review the change the way a careful senior maintainer of this codebase would.
            - Correctness: logic, edge cases, error handling, concurrency, resource handling and security.
            - Design: whether the change fits the surrounding code, whether there's a simpler approach, and whether it duplicates existing helpers.
            - Readability: unclear names, confusing control flow, and comments that are missing where needed or only restate the code.
            - Tests: coverage of the new behavior and its edge cases, and the quality of the tests themselves.
            - Compatibility: effects on APIs, configuration, stored data and migrations.
            Lead with what matters most.
            """, builtIn: true),
        Preset(id: "builtin.scope.security", kind: .scope, name: "Security", text: """
            Review the change for security problems: injection (SQL, command, path, template), gaps in authentication or authorization, unsafe deserialization, SSRF, secrets in code or logs, unsafe defaults, missing validation at trust boundaries, and dependency changes that add risk. Explain how each issue could be exploited. Mention other bugs only if they're serious.
            """, builtIn: true),

        Preset(id: defaultVoiceID, kind: .voice, name: "Colleague", text: """
            Write the way a colleague talks in a pull request: plain, direct sentences with no preamble. Say what the problem is, why it matters and what you'd do instead, then stop. Be specific about what you checked or which input triggers the problem. Phrase points you're unsure of as questions. Include a code suggestion only when it's short and clearly better.
            """, builtIn: true),
        Preset(id: "builtin.voice.terse", kind: .voice, name: "Terse", text: """
            Keep every comment to one or two sentences. No greetings, no restating what the PR does, no hedging. Prefix minor points with "nit:". Keep the summary to three sentences at most.
            """, builtIn: true),
        Preset(id: "builtin.voice.mentor", kind: .voice, name: "Mentor", text: """
            Write for someone who may be new to this codebase. Explain the reasoning behind each point and, when it helps, point to existing code that shows the preferred pattern. Be warm without padding: mention what works only when it's genuinely notable. Make it clear which points must be fixed and which are optional.
            """, builtIn: true),
    ]
}
