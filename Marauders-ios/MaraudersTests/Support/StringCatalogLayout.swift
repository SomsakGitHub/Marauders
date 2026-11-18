//
//  StringCatalogLayout.swift
//  MaraudersTests
//

import Foundation

/// How Xcode writes a string catalog (`.xcstrings`): `"key" : value`, two spaces for each level, text kept as it is (a
/// slash is not escaped, Thai is not written as `\u` escapes), an empty object as `{`, a blank line and `}`, and no
/// newline at the end. The keys of every object come in one of two orders, because Apple's two writers disagree:
/// `xcrun xcstringstool sync` writes code point order, and the String Catalog editor in Xcode (which rewrote this
/// project's catalogs on 2026-11-18, when the app was run from Xcode) writes the order Finder lists names in, case
/// ignored and "@" before "%". Each rewrites a catalog in the other order the first time it saves it.
///
/// A catalog written another way (a script that dumps JSON gives `"key": value`) holds the same texts, but Xcode rewrites
/// the whole file the first time it saves it, and that diff hides the change a person made.
enum StringCatalogLayout {
    /// `nil` when `data` is a catalog in Xcode's layout, in either key order; else where it first differs from the
    /// order it comes closest to.
    static func problem(in data: Data) -> String? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return "the file is not JSON" }
        let written = String(decoding: data, as: UTF8.self)
        let writtenLines = written.components(separatedBy: "\n")
        var closest: (line: Int, message: String)?
        for order in KeyOrder.allCases {
            let expected = render(value, indent: 0, order: order)
            guard written != expected else { return nil }
            guard written != expected + "\n" else { return "the file ends with a newline, Xcode writes none" }
            let expectedLines = expected.components(separatedBy: "\n")
            let differing = zip(writtenLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }
            let line = differing?.offset ?? min(writtenLines.count, expectedLines.count)
            let message =
                differing.map { "line \($0.offset + 1) is `\($0.element.0)`, Xcode writes `\($0.element.1)`" }
                ?? "the file has \(writtenLines.count) lines, Xcode writes \(expectedLines.count)"
            if closest == nil || line > closest?.line ?? 0 { closest = (line, message) }
        }
        return closest?.message
    }

    // MARK: - Writing

    /// The orders a catalog's keys come in (see the type's comment).
    private enum KeyOrder: CaseIterable {
        case codePoint
        case finder

        func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
            switch self {
            case .codePoint:
                return lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
            case .finder:
                // What `localizedStandardCompare` is documented to do, with the locale fixed so that the answer does
                // not depend on the machine that runs the test. Keys that differ only in case come out lowercase
                // first ("Clip location", then "Clip Location"), which is what Xcode wrote.
                return lhs.compare(
                    rhs, options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering], range: nil,
                    locale: Locale(identifier: "en_US")) == .orderedAscending
            }
        }
    }

    private static func render(_ value: JSONValue, indent: Int, order: KeyOrder) -> String {
        let padding = String(repeating: "  ", count: indent)
        switch value {
        case .object(let members):
            guard !members.isEmpty else { return "{\n\n" + padding + "}" }
            let keys = members.keys.sorted(by: order.areInIncreasingOrder)
            let lines = keys.map { key in
                padding + "  " + quote(key) + " : " + render(members[key] ?? .null, indent: indent + 1, order: order)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + padding + "}"
        case .array(let items):
            guard !items.isEmpty else { return "[\n\n" + padding + "]" }
            let lines = items.map { padding + "  " + render($0, indent: indent + 1, order: order) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + padding + "]"
        case .string(let text):
            return quote(text)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .null:
            return "null"
        }
    }

    private static func quote(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case "\u{8}": quoted += "\\b"
            case "\u{C}": quoted += "\\f"
            default:
                if scalar.value < 0x20 {
                    quoted += String(format: "\\u%04x", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    // MARK: - Reading

    private enum JSONValue: Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case bool(Bool)
        case number(Double)
        case null

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let flag = try? container.decode(Bool.self) {
                self = .bool(flag)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let text = try? container.decode(String.self) {
                self = .string(text)
            } else if let items = try? container.decode([JSONValue].self) {
                self = .array(items)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }
    }
}
