import Foundation

/// Vortex rule identifiers are globs, not regular expressions. A non-fuzzy checksum pins the exact file.
enum CollectionReferenceMatcher {
    static func matches(_ entry: NativeCollectionEntry, reference: [String: Any]) -> Bool {
        let tag = reference["tag"] as? String
        let hash = reference["fileMD5"] as? String
        let expression = reference["fileExpression"] as? String
        let logical = reference["logicalFileName"] as? String
        let version = reference["versionMatch"] as? String
        let hasOtherMarker = hash != nil || expression != nil || logical != nil
        if let tag, !tag.isEmpty, entry.tag?.caseInsensitiveCompare(tag) == .orderedSame { return true }
        guard hasOtherMarker else { return false }
        let fuzzy = version.map { $0 == "*" || $0.hasSuffix("+prefer") || $0.contains(where: { "<>^~*xX| ".contains($0) }) } ?? false
        let hashMatches = hash != nil && entry.checksum?.caseInsensitiveCompare(hash!) == .orderedSame
        if hash != nil && !fuzzy && !hashMatches { return false }
        if hashMatches { return true }
        if let logical, entry.logicalFilename?.caseInsensitiveCompare(logical) != .orderedSame,
           entry.name.caseInsensitiveCompare(logical) != .orderedSame, expression == nil { return false }
        if let expression, !glob(entry.fileExpression ?? "", expression),
           !glob(stem(entry.logicalFilename ?? ""), expression), entry.name.caseInsensitiveCompare(expression) != .orderedSame { return false }
        return versionMatches(entry.version, requirement: version)
    }

    static func glob(_ value: String, _ expression: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.caseInsensitiveCompare(expression) == .orderedSame { return true }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: expression)
            .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func stem(_ name: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return stem.replacingOccurrences(of: #"(?:\.\d+| \(\d+\))$"#, with: "", options: .regularExpression)
    }

    static func safeBundleName(_ name: String) -> String {
        name.map { "<>:\"/\\|?*".contains($0) || $0.isNewline ? "_" : $0 }.map(String.init).joined()
    }

    static func bundleMatches(_ name: String, expression: String) -> Bool {
        let candidates = [name, stem(name), safeBundleName(name), stem(safeBundleName(name))]
        let patterns = [expression, stem(expression), safeBundleName(expression), stem(safeBundleName(expression))]
        return candidates.contains { candidate in patterns.contains { glob(candidate, $0) } }
    }

    static func versionMatches(_ version: String?, requirement: String?) -> Bool {
        guard let version, !version.isEmpty, let requirement, !requirement.isEmpty, requirement != "*" else { return true }
        let wanted = String(requirement.split(separator: "+")[0]).trimmingCharacters(in: .whitespaces)
        if version.caseInsensitiveCompare(wanted) == .orderedSame { return true }
        guard let actual = Version(version) else { return false }
        return wanted.components(separatedBy: "||").contains { alternative in
            let text = alternative.trimmingCharacters(in: .whitespaces)
            let bounds = text.components(separatedBy: " - ")
            if bounds.count == 2, let lower = Version(bounds[0]), let upper = Version(bounds[1]) {
                if upper.precision < 3 { return actual >= lower && actual < upper.nextPrecisionBound }
                return actual >= lower && actual <= upper
            }
            let combined = text.replacingOccurrences(of: #"([<>]=?|[=~^])\s+"#, with: "$1", options: .regularExpression)
            let terms = combined.split(whereSeparator: { $0.isWhitespace })
            guard !terms.isEmpty else { return true }
            return terms.allSatisfy { raw in
                let term = String(raw)
                let operators = [">=", "<=", ">", "<", "=", "^", "~"]
                let op = operators.first(where: { term.hasPrefix($0) }) ?? ""
                let number = String(term.dropFirst(op.count))
                let pieces = number.split(separator: ".", omittingEmptySubsequences: false)
                if pieces.contains(where: { $0 == "*" || $0.lowercased() == "x" }) {
                    for (index, part) in pieces.enumerated() {
                        if part == "*" || part.lowercased() == "x" { return true }
                        guard index < actual.parts.count, Int(part) == actual.parts[index] else { return false }
                    }
                    return true
                }
                guard let target = Version(number) else { return false }
                switch op {
                case ">=": return actual >= target
                case "<=": return actual <= target
                case ">": return actual > target
                case "<": return actual < target
                case "^": return actual >= target && actual < target.caretBound
                case "~": return actual >= target && actual < target.tildeBound
                default: return target.precision < 3 ? actual >= target && actual < target.nextPrecisionBound : actual == target
                }
            }
        }
    }

    private struct Version: Comparable {
        var parts: [Int]
        var prerelease: String?
        var precision: Int
        init?(_ text: String) {
            let clean = text.trimmingCharacters(in: .whitespaces).lowercased().drop(while: { $0 == "v" || $0 == "=" })
            guard !clean.isEmpty else { return nil }
            let core = clean.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)
            let components = core[0].split(separator: ".")
            guard !components.isEmpty, components.count <= 3 else { return nil }
            let numbers = components.compactMap { Int($0) }
            guard numbers.count == components.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
            precision = numbers.count
            parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
            prerelease = core.count > 1 ? String(core[1]) : nil
        }
        private init(parts: [Int]) { self.parts = parts; self.prerelease = nil; self.precision = 3 }
        var nextPrecisionBound: Version {
            var next = parts
            let index = max(0, precision - 1)
            next[index] += 1
            for i in (index + 1)..<3 { next[i] = 0 }
            return Version(parts: next)
        }
        var tildeBound: Version {
            var next = parts
            let index = precision == 1 ? 0 : 1
            next[index] += 1
            for i in (index + 1)..<3 { next[i] = 0 }
            return Version(parts: next)
        }
        var caretBound: Version {
            var next = parts
            let index = parts.firstIndex(where: { $0 != 0 }) ?? min(precision - 1, 2)
            next[index] += 1
            for i in (index + 1)..<3 { next[i] = 0 }
            return Version(parts: next)
        }
        static func == (lhs: Version, rhs: Version) -> Bool { lhs.parts == rhs.parts && lhs.prerelease == rhs.prerelease }
        static func < (lhs: Version, rhs: Version) -> Bool {
            for i in 0..<3 where lhs.parts[i] != rhs.parts[i] { return lhs.parts[i] < rhs.parts[i] }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case (let left?, let right?): return left.compare(right, options: .numeric) == .orderedAscending
            }
        }
    }
}
