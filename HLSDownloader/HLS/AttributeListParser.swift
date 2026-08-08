import Foundation

enum AttributeListParser {
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var fields: [String] = []
        var current = ""
        var insideQuotes = false

        for character in text {
            if character == "\"" {
                insideQuotes.toggle()
                current.append(character)
            } else if character == "," && !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            fields.append(current)
        }

        for field in fields {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let key = field[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            var value = field[field.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }
}

