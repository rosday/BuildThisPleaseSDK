import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol BuildThisPleaseTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionBuildThisPleaseTransport: BuildThisPleaseTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw BuildThisPleaseError.invalidResponse }
            return (data, response)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw BuildThisPleaseError.offline
        }
    }
}

struct APIErrorEnvelope: Decodable { let error: APIErrorBody }
struct APIErrorBody: Decodable { let code: String; let message: String }

enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }

    static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO 8601 date")
        }
        return value
    }
}

extension Data {
    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var base64URLDecodedData: Data? {
        let normalized = replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: normalized.padding(toLength: ((normalized.count + 3) / 4) * 4, withPad: "=", startingAt: 0))
    }
}

func sha256(_ data: Data) -> Data {
    #if canImport(CryptoKit)
    return Data(CryptoKit.SHA256.hash(data: data))
    #else
    fatalError("CryptoKit is required")
    #endif
}

#if canImport(CryptoKit)
import CryptoKit
#endif
