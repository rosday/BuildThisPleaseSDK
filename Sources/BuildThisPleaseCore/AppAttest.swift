import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

public protocol BuildThisPleaseAttestationProvider: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

public struct DeviceCheckAttestationProvider: BuildThisPleaseAttestationProvider {
    public init() {}
    public var isSupported: Bool {
        #if canImport(DeviceCheck)
        DCAppAttestService.shared.isSupported
        #else
        false
        #endif
    }

    public func generateKey() async throws -> String {
        #if canImport(DeviceCheck)
        return try await DCAppAttestService.shared.generateKey()
        #else
        throw BuildThisPleaseError.appAttestUnavailable
        #endif
    }

    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        return try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
        #else
        throw BuildThisPleaseError.appAttestUnavailable
        #endif
    }

    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        return try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
        #else
        throw BuildThisPleaseError.appAttestUnavailable
        #endif
    }
}
