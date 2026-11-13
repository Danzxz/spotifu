import Foundation

public struct LyricLine: Identifiable, Equatable {
    public var id: Int
    public var time: Double
    public var text: String
    public static func parse(_ lrc: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d{1,2}(?:\\.\\d+)?)\\]")
        var result: [LyricLine] = []
        for line in lrc.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                      let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                result.append(LyricLine(id: result.count, time: minutes * 60 + seconds, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}
