// SymbolCatalog.swift
// The system's own SF Symbols index, read from CoreGlyphs.bundle (plain
// plists that ship with macOS: the canonical name order and the search
// terms the SF Symbols app uses). No private API — and no hand-maintained
// list of 9,000 names. Locale-specific variants (`.ar`, `.hi`, …) are left
// out: they are the same glyph with a different script.

import Foundation

enum SymbolCatalog {
    struct Entry {
        let name: String
        let terms: [String]
    }

    private nonisolated static let resources = URL(fileURLWithPath:
        "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// Localized variants end in a short script code. Anything else that
    /// short (`.fill`, `.slash`, `.rtl`) is a real variant and stays.
    private nonisolated static let localeSuffixes: Set<String> = [
        "ar", "he", "hi", "ja", "ko", "th", "zh", "el", "ru", "bn", "gu", "kn", "ml",
        "mr", "my", "or", "pa", "si", "ta", "te", "km", "lo", "mn", "ka", "hy", "ur",
        "fa", "vi", "ms", "id", "tr", "uk", "pl", "cs", "hu", "sk", "ro", "bg", "sr",
        "hr", "sl", "lt", "lv", "et", "fi", "sv", "da", "no", "nl", "de", "fr", "es",
        "pt", "it", "ca", "am", "ti", "sat", "syriac", "cyr", "grc",
    ]

    static let all: [Entry] = {
        func plist(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        let order = plist("symbol_order.plist") as? [String] ?? []
        let search = plist("symbol_search.plist") as? [String: [String]] ?? [:]
        return order.compactMap { name in
            if let last = name.split(separator: ".").last, localeSuffixes.contains(String(last)) {
                return nil
            }
            return Entry(name: name, terms: search[name] ?? [])
        }
    }()

    /// As-you-type search: name prefix, then a dotted component prefix
    /// ("star" → "circle.star"), then name substring, then the search terms.
    /// Order within a tier is the catalog's own.
    static func search(_ query: String, limit: Int = 240) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var tiers: [[String]] = [[], [], [], []]
        for entry in all {
            let name = entry.name
            if name.hasPrefix(q) {
                tiers[0].append(name)
            } else if name.split(separator: ".").contains(where: { $0.hasPrefix(q) }) {
                tiers[1].append(name)
            } else if name.contains(q) {
                tiers[2].append(name)
            } else if entry.terms.contains(where: { $0.hasPrefix(q) || $0.contains(" " + q) }) {
                tiers[3].append(name)
            }
        }
        return Array(tiers.flatMap { $0 }.prefix(limit))
    }
}
