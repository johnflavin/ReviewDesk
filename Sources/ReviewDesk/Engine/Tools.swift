import Foundation

/// Finds the command-line tools the app drives, and the environment to run them in.
/// Apps launched from Finder get a minimal PATH, so common install locations are added.
enum Tools {
    static let home = NSHomeDirectory()

    static let searchPath: [String] = [
        "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "\(home)/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        var seen = Set<String>()
        let inherited = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (searchPath + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env[key] = nil }
        return env
    }()

    static func locate(_ name: String, override: String = "") -> String? {
        let fm = FileManager.default
        let custom = expand(override)
        if !custom.isEmpty { return fm.isExecutableFile(atPath: custom) ? custom : nil }
        return searchPath.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct Git: Sendable {
    let path: String
    /// Used for HTTPS fetches and clones.
    var token: String?

    static func make(token: String? = nil) -> Git? {
        Tools.locate("git").map { Git(path: $0, token: token) }
    }

    /// Answers git's credential requests with the token from the environment, so it never appears in arguments.
    private static let credentialHelper =
        "!f() { test \"$1\" = get && printf 'username=x-access-token\\npassword=%s\\n' \"$REVIEWDESK_GIT_TOKEN\"; }; f"

    /// Skips the repository's hooks and the user's credential helpers.
    private var config: [String] {
        var config = ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper="]
        if token != nil { config += ["-c", "credential.helper=\(Self.credentialHelper)"] }
        return config
    }

    private var environment: [String: String] {
        token.map { ["REVIEWDESK_GIT_TOKEN": $0] } ?? [:]
    }

    /// Returns trimmed stdout.
    @discardableResult
    func run(_ args: [String], in dir: String?) async throws -> String {
        try await Shell.check(path, config + args, cwd: dir, env: environment)
    }

    /// Returns stdout untouched.
    func output(_ args: [String], in dir: String?) async throws -> String {
        let result = try await Shell.run(path, config + args, cwd: dir, env: environment)
        guard result.status == 0 else {
            throw ShellError(command: Shell.label(path, args), status: result.status, output: result.stderr)
        }
        return result.stdout
    }

    func succeeds(_ args: [String], in dir: String?) async -> Bool {
        (try? await Shell.run(path, config + args, cwd: dir, env: environment))?.status == 0
    }
}
