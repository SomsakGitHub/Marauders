//
//  StringCatalogAudit.swift
//  MaraudersTests
//

import Foundation

/// Reads a string catalog (`.xcstrings`) and says which of its keys would leave a language without its text.
///
/// The guard tests run it on the committed catalogs: a key the app shows needs a Thai text, and that text has to take
/// the arguments of the English one, or a Thai screen shows English (or a wrong value) in that place.
struct StringCatalogAudit {
    struct Problem: Equatable, CustomStringConvertible {
        let key: String
        let reason: String

        var description: String { "\(key): \(reason)" }
    }

    private let catalog: Catalog

    init(data: Data) throws {
        catalog = try JSONDecoder().decode(Catalog.self, from: data)
    }

    /// The keys with no text in `language`, or with a text there that does not take the placeholders of the English
    /// text, sorted by key. A key the sources no longer use (stale) and a key marked "don't translate" are left out.
    func problems(language: String = "th") -> [Problem] {
        var problems: [Problem] = []
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) {
            guard entry.extractionState != "stale", entry.shouldTranslate != false else { continue }
            let texts = entry.texts(in: language)
            guard !texts.isEmpty else {
                problems.append(Problem(key: key, reason: "no \(language) text"))
                continue
            }
            let english = entry.texts(in: catalog.sourceLanguage).first ?? key
            let expected = Self.placeholders(of: english)
            if expected == nil || texts.contains(where: { Self.placeholders(of: $0) != expected }) {
                problems.append(Problem(key: key, reason: "placeholders differ"))
            }
        }
        return problems
    }

    /// For a catalog whose keys are names, like the one of Info.plist: each of `keys` without a text in one of
    /// `languages`.
    func missing(languages: [String], forKeys keys: [String]) -> [Problem] {
        var problems: [Problem] = []
        for key in keys {
            for language in languages where catalog.strings[key]?.texts(in: language).isEmpty ?? true {
                problems.append(Problem(key: key, reason: "no \(language) text"))
            }
        }
        return problems
    }

    /// Whether the catalog has an entry for `key`.
    func hasKey(_ key: String) -> Bool {
        catalog.strings[key] != nil
    }

    /// The first text of `key` in `language`: `nil` when the key or the language is missing, or the text is blank.
    func text(forKey key: String, language: String) -> String? {
        catalog.strings[key]?.texts(in: language).first
    }

    /// The type of each argument a format text takes, by position: `"%@ has %lld"` gives `[1: "@", 2: "lld"]`, and so
    /// does `"%2$lld of %1$@"`. `nil` when the text mixes positions with plain placeholders or gives one position two
    /// types. `%%` is a percent sign, not a placeholder.
    static func placeholders(of text: String) -> [Int: String]? {
        let specifier = /%(?:%|(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@a-zA-Z]))/
        var types: [Int: String] = [:]
        var next = 1
        var usesPositions: Bool?
        for match in text.matches(of: specifier) {
            guard let conversion = match.3 else { continue }
            let type = (match.2.map { String($0) } ?? "") + conversion
            let hasPosition = match.1 != nil
            if let usesPositions, usesPositions != hasPosition { return nil }
            usesPositions = hasPosition
            let position = match.1.flatMap { Int($0) } ?? next
            next += 1
            if let known = types[position], known != type { return nil }
            types[position] = type
        }
        return types
    }

    // MARK: - The file

    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let extractionState: String?
        let shouldTranslate: Bool?
        let localizations: [String: Localization]?

        /// The texts the entry has in `language` that are not blank.
        func texts(in language: String) -> [String] {
            (localizations?[language]?.texts ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    /// One language of an entry: one text, or one text per plural form or device.
    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: [String: [String: Localization]]?

        var texts: [String] {
            let own = stringUnit.map { [$0.value] } ?? []
            return own + (variations?.values.flatMap { $0.values.flatMap(\.texts) } ?? [])
        }
    }

    private struct StringUnit: Decodable {
        let value: String
    }
}
