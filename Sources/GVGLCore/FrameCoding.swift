import Foundation

// MARK: - JSON

public extension JSONEncoder {
    static var gvgl: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        // No sortedKeys: struct property order is already deterministic, and
        // key sorting measurably slows large-frame serialization.
        return enc
    }
}

public extension JSONDecoder {
    static var gvgl: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return dec
    }
}
