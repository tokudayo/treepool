import Foundation

private struct CopyPatternMatcher {
    let pattern: String
    let regex: NSRegularExpression
}

extension TreepoolManager {
    func copyConfiguredFiles(
        from sourceRoot: URL,
        to destinationRoot: URL,
        patterns: [String]
    ) throws -> [String] {
        let normalizedPatterns = try normalizedCopyPatterns(patterns)
        guard !normalizedPatterns.isEmpty else { return [] }
        let matchers = try normalizedPatterns.map { pattern in
            CopyPatternMatcher(pattern: pattern, regex: try globRegex(for: pattern))
        }
        let normalizedSourceRoot = sourceRoot.standardizedFileURL
        let prefix = normalizedSourceRoot.path.hasSuffix("/")
            ? normalizedSourceRoot.path
            : normalizedSourceRoot.path + "/"

        guard let enumerator = fileManager.enumerator(
            at: normalizedSourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            throw TreepoolError.unsafe("Could not enumerate repository files for copyPatterns.")
        }

        var matchesByPattern = Dictionary(
            uniqueKeysWithValues: normalizedPatterns.map { ($0, Set<String>()) }
        )
        for case let sourceURL as URL in enumerator {
            let standardized = sourceURL.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else { continue }
            let relativePath = String(standardized.path.dropFirst(prefix.count))
            guard !relativePath.isEmpty else { continue }
            let isGitMetadata = relativePath == ".git" || relativePath.hasPrefix(".git/")
            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                if isGitMetadata { enumerator.skipDescendants() }
                continue
            }
            if isGitMetadata { continue }
            let range = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
            for matcher in matchers
                where matcher.regex.firstMatch(in: relativePath, range: range) != nil {
                matchesByPattern[matcher.pattern, default: []].insert(relativePath)
            }
        }

        var warnings: [String] = []
        var matchedPaths: Set<String> = []
        for pattern in normalizedPatterns {
            let matches = matchesByPattern[pattern] ?? []
            if matches.isEmpty {
                warnings.append("copyPatterns pattern '\(pattern)' matched no files.")
            }
            matchedPaths.formUnion(matches)
        }
        try copy(matchedPaths.sorted(), from: normalizedSourceRoot, to: destinationRoot)
        return warnings
    }

    func normalizedCopyPatterns(_ patterns: [String]) throws -> [String] {
        var seen: Set<String> = []
        return try patterns.compactMap { pattern in
            let value = try normalizedCopyPattern(pattern)
            return seen.insert(value).inserted ? value : nil
        }
    }

    private func copy(_ paths: [String], from sourceRoot: URL, to destinationRoot: URL) throws {
        for relativePath in paths {
            let sourceURL = sourceRoot.appendingPathComponent(relativePath)
            let destinationURL = destinationRoot.appendingPathComponent(relativePath)
            do {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let exists = fileManager.fileExists(atPath: destinationURL.path)
                    || (try? fileManager.destinationOfSymbolicLink(atPath: destinationURL.path)) != nil
                if exists { try fileManager.removeItem(at: destinationURL) }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                throw TreepoolError.unsafe(
                    "Failed to copy '\(relativePath)' into \(destinationRoot.path): \(error.localizedDescription)"
                )
            }
        }
    }

    private func normalizedCopyPattern(_ pattern: String) throws -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TreepoolError.invalidConfig("copyPatterns entries must not be empty")
        }
        var normalized = trimmed
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        guard !normalized.isEmpty else {
            throw TreepoolError.invalidConfig("copyPatterns entries must not be empty")
        }
        guard !normalized.hasPrefix("/") else {
            throw TreepoolError.invalidConfig("copyPatterns must be repository-relative paths")
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: \.isEmpty) else {
            throw TreepoolError.invalidConfig(
                "copyPatterns must not contain empty path components"
            )
        }
        guard !components.contains(where: { $0 == ".." }) else {
            throw TreepoolError.invalidConfig("copyPatterns must not escape the repository root")
        }
        guard !components.contains(where: { $0 == ".git" }) else {
            throw TreepoolError.invalidConfig("copyPatterns must not target .git metadata")
        }
        return normalized
    }

    private func globRegex(for pattern: String) throws -> NSRegularExpression {
        let regexMetaCharacters: Set<Character> = [
            "\\", ".", "+", "(", ")", "|", "^", "$", "[", "]", "{", "}"
        ]
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterNext = pattern.index(after: next)
                    if afterNext < pattern.endIndex, pattern[afterNext] == "/" {
                        regex += "(?:.*/)?"
                        index = pattern.index(after: afterNext)
                    } else {
                        regex += ".*"
                        index = afterNext
                    }
                } else {
                    regex += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                regex += "[^/]"
                index = pattern.index(after: index)
            } else {
                if regexMetaCharacters.contains(character) { regex.append("\\") }
                regex.append(character)
                index = pattern.index(after: index)
            }
        }
        do {
            return try NSRegularExpression(pattern: regex + "$")
        } catch {
            throw TreepoolError.invalidConfig(
                "copyPatterns contains an invalid pattern '\(pattern)'"
            )
        }
    }
}
