import Foundation

/// One line of text read from a screenshot. Coordinates are normalized with the origin at the bottom left, as Vision reports them.
struct OCRLine {
    let text: String
    let midY: Double
    let minX: Double
    let height: Double
}

struct SizedRow: Identifiable, Equatable {
    let name: String
    let bytes: Int64
    var id: String { name.lowercased() }
}

/// Turns the text of an iPhone Storage or WhatsApp Manage storage screenshot into named sizes.
/// ponytail: matches screen layout by geometry, so a new iOS layout can misread. Wrong rows can be swiped away.
enum StorageScreenshot {
    private static let size = /^(.*?)\s*(\d+(?:[.,]\d+)?)\s*(KB|MB|GB|TB|Ko|Mo|Go|To)$/.ignoresCase()

    static func rows(from lines: [OCRLine]) -> [SizedRow] {
        var result: [SizedRow] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard let match = text.wholeMatch(of: size), let bytes = bytes(String(match.2), unit: String(match.3)) else { continue }
            let inlineName = String(match.1).trimmingCharacters(in: .whitespaces)
            if !inlineName.isEmpty {
                result.append(SizedRow(name: inlineName, bytes: bytes))
            } else if let name = nameLine(for: line, in: lines) {
                result.append(SizedRow(name: name, bytes: bytes))
            }
        }
        return result
    }

    /// Keeps one row per name, across screenshots that overlap, largest first.
    static func merged(_ rows: [SizedRow]) -> [SizedRow] {
        Dictionary(rows.map { ($0.id, $0) }) { $0.bytes >= $1.bytes ? $0 : $1 }.values
            .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    /// iOS shows "Last used" under the name, so only text level with or above the size can be the name.
    private static func nameLine(for sizeLine: OCRLine, in lines: [OCRLine]) -> String? {
        let reach = sizeLine.height * 3
        return lines
            .filter { other in
                let rise = other.midY - sizeLine.midY
                return rise >= -sizeLine.height / 4 && rise <= reach
                    && other.minX <= sizeLine.minX + 0.01
                    && other.text.wholeMatch(of: size) == nil
                    && other.text.contains(where: \.isLetter)
            }
            .min { abs($0.midY - sizeLine.midY) < abs($1.midY - sizeLine.midY) }?
            .text.trimmingCharacters(in: .whitespaces)
    }

    private static func bytes(_ number: String, unit: String) -> Int64? {
        var digits = number
        // "1,024" and "1.024" are thousands. "1,5" and "1.52" are decimals.
        if let separator = digits.firstIndex(where: { $0 == "." || $0 == "," }), digits.distance(from: separator, to: digits.endIndex) == 4 {
            digits.remove(at: separator)
        }
        guard let value = Double(digits.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let scale: Double
        switch unit.uppercased().first {
        case "K": scale = 1e3
        case "M": scale = 1e6
        case "G": scale = 1e9
        default: scale = 1e12
        }
        return Int64(value * scale)
    }
}

/// Everything after the oldest item of each group of identical items.
func duplicateExtras<T, K: Hashable>(_ items: [T], key: (T) -> K, date: (T) -> Date) -> [T] {
    Dictionary(grouping: items, by: key).values.flatMap { $0.sorted { date($0) < date($1) }.dropFirst() }
}
