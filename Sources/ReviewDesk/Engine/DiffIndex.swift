import Foundation

/// The new-file lines a unified diff shows, which are the lines GitHub accepts inline comments on.
struct DiffIndex {
    private var lines: [String: Set<Int>] = [:]
    private var hunks: [String: [ClosedRange<Int>]] = [:]

    init(diff: String) {
        var path: String?
        var oldLeft = 0, newLeft = 0, newLine = 0, hunkStart = 0

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if oldLeft > 0 || newLeft > 0 {
                switch raw.first {
                case "+":
                    if let path { lines[path, default: []].insert(newLine) }
                    newLine += 1; newLeft -= 1
                case "-":
                    oldLeft -= 1
                case "\\":
                    break
                default:
                    if let path { lines[path, default: []].insert(newLine) }
                    newLine += 1; newLeft -= 1; oldLeft -= 1
                }
                if oldLeft <= 0, newLeft <= 0, let path, newLine > hunkStart {
                    hunks[path, default: []].append(hunkStart...(newLine - 1))
                }
                continue
            }
            if raw.hasPrefix("diff --git ") {
                path = nil
            } else if raw.hasPrefix("+++ ") {
                path = Self.cleanPath(raw.dropFirst(4))
            } else if raw.hasPrefix("@@ "), let hunk = Self.parseHunk(raw) {
                newLine = hunk.newStart
                hunkStart = hunk.newStart
                oldLeft = hunk.oldCount
                newLeft = hunk.newCount
            }
        }
    }

    /// The diff with each hunk line prefixed by its line number in the new file (blank for removed lines),
    /// so the agent can cite file line numbers rather than positions in the diff.
    static func annotate(_ diff: String) -> String {
        var out: [String] = []
        var oldLeft = 0, newLeft = 0, newLine = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if oldLeft > 0 || newLeft > 0 {
                switch raw.first {
                case "+":
                    out.append(String(format: "%6d + ", newLine) + raw.dropFirst())
                    newLine += 1; newLeft -= 1
                case "-":
                    out.append("       - " + raw.dropFirst())
                    oldLeft -= 1
                case "\\":
                    out.append("         " + raw)
                default:
                    out.append(String(format: "%6d   ", newLine) + raw.dropFirst())
                    newLine += 1; newLeft -= 1; oldLeft -= 1
                }
                continue
            }
            if raw.hasPrefix("@@ "), let hunk = parseHunk(raw) {
                newLine = hunk.newStart
                oldLeft = hunk.oldCount
                newLeft = hunk.newCount
            }
            out.append(String(raw))
        }
        return out.joined(separator: "\n")
    }

    init(path: String) {
        self.init(diff: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    /// Marks whether the comment can be posted inline, and drops a range GitHub wouldn't accept.
    func place(_ comment: inout DraftComment) {
        comment.inDiff = contains(path: comment.path, line: comment.line)
        if let start = comment.startLine,
           !(comment.inDiff && start < comment.line && sameHunk(path: comment.path, start, comment.line)) {
            comment.startLine = nil
        }
    }

    func contains(path: String, line: Int) -> Bool {
        lines[path]?.contains(line) ?? false
    }

    func sameHunk(path: String, _ a: Int, _ b: Int) -> Bool {
        hunks[path]?.contains { $0.contains(a) && $0.contains(b) } ?? false
    }

    private static func cleanPath(_ raw: Substring) -> String? {
        var path = raw
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = path.dropFirst().dropLast() }
        if path == "/dev/null" { return nil }
        if path.hasPrefix("b/") { path = path.dropFirst(2) }
        return String(path)
    }

    private static func parseHunk(_ line: Substring) -> (newStart: Int, oldCount: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (start: Int, count: Int)? {
            let numbers = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(numbers[0]) else { return nil }
            return (start, numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (new.start, old.count, new.count)
    }
}
