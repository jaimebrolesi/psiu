import Foundation

// Claude Code's settings.json and the events it sends can hold anything, so they are read as loose JSON.
// Psiu's own files have a fixed shape and use the Codable models in Models.swift.

func readJSON(_ url: URL) -> [String: Any]? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Pretty output sorts its keys, so the user's settings.json comes out in the same order on every install.
func writeJSON(_ obj: [String: Any], to url: URL, pretty: Bool = false) {
    let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys] : []
    do {
        let d = try JSONSerialization.data(withJSONObject: obj, options: opts)
        try d.write(to: url, options: .atomic)
    } catch {
        Log.core.error("Couldn't write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

/// Reads one of Psiu's own files; nil when it is missing or unreadable.
public func readFile<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        Log.core.debug("Couldn't read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// Writes one of Psiu's own files, atomically.
public func writeFile<T: Encodable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    do {
        try encoder.encode(value).write(to: url, options: .atomic)
    } catch {
        Log.core.error("Couldn't write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}

extension KeyedDecodingContainer {
    /// A field of the wrong type reads as missing, as the loose JSON did, instead of making the whole file unreadable.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }

    /// Numbers that older versions may have written as Double or as Int.
    func number(_ key: Key) -> Double? {
        if let d = lenient(Double.self, key) { return d }
        return lenient(Int.self, key).map(Double.init)
    }
}
