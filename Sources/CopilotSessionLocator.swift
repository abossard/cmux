import Foundation

// MARK: - Copilot workspace.yaml parser

/// Parses Copilot CLI `workspace.yaml` files and enumerates sessions
/// from `~/.copilot/session-state/`.
///
/// Uses simple line-by-line key:value parsing to avoid a YAML dependency.
/// workspace.yaml is flat (no nesting) with well-known keys.
enum CopilotSessionLocator {

    struct WorkspaceMetadata: Hashable {
        let id: String
        let cwd: String?
        let repository: String?
        let branch: String?
        let name: String?
        let summary: String?
        let createdAt: Date?
        let updatedAt: Date?
    }

    // MARK: - Session root

    static var sessionStateRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state", isDirectory: true)
    }

    // MARK: - Enumerate sessions

    /// Returns session directories sorted by mtime (newest first), applying
    /// optional needle/cwd filters. Each directory is expected to contain a
    /// `workspace.yaml`.
    static func enumerateSessions(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) -> [SessionEntry] {
        let fm = FileManager.default
        let root = sessionStateRoot
        guard fm.fileExists(atPath: root.path) else { return [] }

        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Collect candidates with mtime
        var candidates: [(url: URL, mtime: Date)] = []
        for dir in contents {
            guard let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true else { continue }
            let yamlURL = dir.appendingPathComponent("workspace.yaml")
            let mtime: Date
            if let yamlAttrs = try? fm.attributesOfItem(atPath: yamlURL.path),
               let yamlMtime = yamlAttrs[.modificationDate] as? Date {
                mtime = yamlMtime
            } else if let dirMtime = values.contentModificationDate {
                mtime = dirMtime
            } else {
                continue
            }
            candidates.append((dir, mtime))
        }

        candidates.sort { $0.mtime > $1.mtime }

        let target = offset + limit
        let workSize = min(target * 2, candidates.count, 500)
        let workCandidates = Array(candidates.prefix(workSize))

        var entries: [SessionEntry] = []
        for candidate in workCandidates {
            guard entries.count < target else { break }

            let yamlURL = candidate.url.appendingPathComponent("workspace.yaml")
            guard let meta = parseWorkspaceYaml(at: yamlURL) else { continue }

            if let cwdFilter, meta.cwd != cwdFilter { continue }

            var title = meta.name ?? meta.summary ?? ""
            if title.isEmpty {
                title = firstUserMessage(in: candidate.url) ?? meta.repository ?? candidate.url.lastPathComponent
            }
            // Truncate excessively long titles
            if title.count > 120 {
                title = String(title.prefix(117)) + "…"
            }

            if !needle.isEmpty {
                let searchable = [title, meta.cwd ?? "", meta.repository ?? "", meta.branch ?? ""]
                    .joined(separator: " ")
                if searchable.range(of: needle, options: [.caseInsensitive, .literal]) == nil {
                    continue
                }
            }

            // Point fileURL at events.jsonl (the JSONL transcript) instead of
            // workspace.yaml so the Vault transcript loader can parse messages.
            // Fall back to yamlURL when events.jsonl doesn't exist yet.
            let eventsURL = candidate.url.appendingPathComponent("events.jsonl")
            let transcriptURL: URL = FileManager.default.fileExists(atPath: eventsURL.path) ? eventsURL : yamlURL

            let entry = SessionEntry(
                id: "copilot:" + meta.id,
                agent: .copilot,
                sessionId: meta.id,
                title: title,
                cwd: meta.cwd,
                gitBranch: meta.branch,
                pullRequest: nil,
                modified: meta.updatedAt ?? candidate.mtime,
                fileURL: transcriptURL,
                specifics: .copilot(model: nil)
            )
            entries.append(entry)
        }

        return Array(entries.dropFirst(offset).prefix(limit))
    }

    // MARK: - workspace.yaml parser

    /// Parses a flat workspace.yaml with simple key: value lines.
    /// Tolerates quoted values, `null`/`~`, and multiline `|-` blocks (skips them).
    static func parseWorkspaceYaml(at url: URL) -> WorkspaceMetadata? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var dict: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)
        var inMultilineBlock = false

        for line in lines {
            // Skip multiline block content (indented lines after `|-`)
            if inMultilineBlock {
                if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    inMultilineBlock = false
                } else {
                    continue
                }
            }

            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix(" "), !key.hasPrefix("\t") else { continue }

            var value = String(line[line.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Check for multiline block indicator
            if value == "|-" || value == "|" || value == ">" || value == ">-" {
                inMultilineBlock = true
                continue
            }

            // Handle null/empty
            if value.isEmpty || value == "null" || value == "~" {
                continue
            }

            // Strip surrounding quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            dict[key] = value
        }

        guard let id = dict["id"], !id.isEmpty else { return nil }

        return WorkspaceMetadata(
            id: id,
            cwd: dict["cwd"],
            repository: dict["repository"],
            branch: dict["branch"],
            name: dict["name"],
            summary: dict["summary"],
            createdAt: dict["created_at"].flatMap(parseISO8601),
            updatedAt: dict["updated_at"].flatMap(parseISO8601)
        )
    }

    // MARK: - First user message fallback

    /// Reads the first `user.message` from events.jsonl for title fallback.
    /// Only reads the first 32 KB to avoid loading large transcript files.
    private static func firstUserMessage(in sessionDir: URL) -> String? {
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return nil }
        defer { try? handle.close() }

        let headData = handle.readData(ofLength: 32_768)
        guard let content = String(data: headData, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user.message" else { continue }

            if let userContent = obj["user_content"] as? String,
               !userContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(userContent.prefix(200))
            }
            if let dataDict = obj["data"] as? [String: Any],
               let content = dataDict["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(content.prefix(200))
            }
        }
        return nil
    }

    // MARK: - ISO 8601 parser

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? isoFormatterNoFrac.date(from: string)
    }
}
