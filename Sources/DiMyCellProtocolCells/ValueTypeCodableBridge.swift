import Foundation
import CellBase

enum ValueTypeCodableBridge {
    static func decode<T: Decodable>(_ type: T.Type, from value: ValueType) -> T? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> ValueType {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            return .null
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ValueType.self, from: data)) ?? .null
    }

    static func asUInt64(_ value: ValueType?) -> UInt64? {
        switch value {
        case .integer(let intValue):
            return intValue < 0 ? nil : UInt64(intValue)
        case .number(let intValue):
            return intValue < 0 ? nil : UInt64(intValue)
        case .float(let doubleValue):
            guard doubleValue >= 0 else { return nil }
            return UInt64(doubleValue)
        case .string(let stringValue):
            return UInt64(stringValue)
        default:
            return nil
        }
    }

    static func asString(_ value: ValueType?) -> String? {
        if case let .string(raw)? = value {
            return raw
        }
        return nil
    }
}
