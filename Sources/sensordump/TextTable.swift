/// Minimal fixed-width text table for terminal output.
struct TextTable {
    enum Alignment { case left, right }

    var headers: [String]
    var alignments: [Alignment]
    var rows: [[String]] = []

    init(_ headers: [String], alignments: [Alignment]? = nil) {
        self.headers = headers
        self.alignments = alignments ?? headers.map { _ in .left }
    }

    mutating func add(_ row: [String]) {
        rows.append(row)
    }

    func render(indent: String = "  ") -> String {
        let all = [headers] + rows
        let widths = headers.indices.map { column in
            all.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            let padded = headers.indices.map { column -> String in
                let cell = column < cells.count ? cells[column] : ""
                let padding = String(repeating: " ", count: widths[column] - cell.count)
                return alignments[column] == .right ? padding + cell : cell + padding
            }
            return indent + padded.joined(separator: "  ").trimmingTrailingSpaces()
        }
        var output = [line(headers)]
        output.append(indent + widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        output += rows.map(line)
        return output.joined(separator: "\n")
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
