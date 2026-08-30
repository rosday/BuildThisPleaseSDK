import Foundation

public protocol BuildThisPleaseClientProtocol: Sendable {
    func configuration() async throws -> BuildThisPleaseConfigurationResponse
    func requests() async throws -> [BuildThisPleaseTicket]
    func myRequests() async throws -> [BuildThisPleaseTicket]
    func implementedRequests() async throws -> [BuildThisPleaseTicket]
    func ticket(id: String) async throws -> BuildThisPleaseTicket
    func comments(ticketId: String) async throws -> [BuildThisPleaseComment]
    func createTicket(title: String, description: String, idempotencyKey: String) async throws -> BuildThisPleaseTicket
    func createTicket(title: String, description: String, email: String?, idempotencyKey: String) async throws -> BuildThisPleaseTicket
    func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket
    func createComment(ticketId: String, body: String, idempotencyKey: String) async throws -> BuildThisPleaseComment
    func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment
    func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws
}

public extension BuildThisPleaseClientProtocol {
    func createTicket(title: String, description: String, email: String?, idempotencyKey: String) async throws -> BuildThisPleaseTicket {
        try await createTicket(title: title, description: description, idempotencyKey: idempotencyKey)
    }
}

public actor BuildThisPleaseClient: BuildThisPleaseClientProtocol {
    private struct Session: Codable, Sendable { let token: String; let installationId: String; let expiresAt: Date }
    private struct SessionEnvelope: Decodable { let sessionToken: String; let installationId: String; let expiresAt: Date }
    private struct TicketEnvelope: Decodable { let ticket: BuildThisPleaseTicket }
    private struct CommentEnvelope: Decodable { let comment: BuildThisPleaseComment }
    private struct CommentPage: Decodable { let items: [BuildThisPleaseComment] }
    private struct RegistrationChallenge: Decodable { let challengeId: String; let challenge: String }
    private struct AssertionChallenge: Decodable { let challengeId: String; let challengeHash: String; let requestHash: String }
    private struct RegistrationBody: Encodable { let challengeId: String; let keyId: String; let attestationObject: String }
    private struct RecoveryChallengeBody: Encodable { let keyId: String }
    private struct RecoveryBody: Encodable { let challengeId: String; let keyId: String; let assertionObject: String }
    private struct TicketBody: Encodable { let title: String; let description: String; let email: String? }
    private struct CommentBody: Encodable { let body: String }
    private struct SubscriptionBody: Encodable { let status: BuildThisPleaseSubscriptionStatus; let observedAt: Date }
    private struct UserIdentityBody: Encodable {
        let revenueCatAppUserID: String?
        let userEmail: String?

        enum CodingKeys: String, CodingKey {
            case revenueCatAppUserID = "revenueCatAppUserId"
            case userEmail
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(revenueCatAppUserID, forKey: .revenueCatAppUserID)
            try container.encode(userEmail, forKey: .userEmail)
        }
    }
    private struct AssertionChallengeBody: Encodable { let method: String; let path: String; let bodyHash: String }
    private struct RegistrationChallengeBody: Encodable {
        let bundleId: String
        let environment: String
        let appVersion: String?
        let osVersion: String
        let subscriptionStatus: BuildThisPleaseSubscriptionStatus
        let revenueCatAppUserId: String?
        let userEmail: String?
    }

    private var config: BuildThisPleaseConfiguration
    private let transport: any BuildThisPleaseTransport
    private let credentials: any BuildThisPleaseCredentialStore
    private let attestation: any BuildThisPleaseAttestationProvider
    private let credentialPrefix: String
    private var memorySession: Session?
    private var sessionTask: Task<Session, Error>?

    public init(
        configuration: BuildThisPleaseConfiguration,
        transport: any BuildThisPleaseTransport = URLSessionBuildThisPleaseTransport(),
        credentialStore: any BuildThisPleaseCredentialStore = KeychainBuildThisPleaseCredentialStore(),
        attestationProvider: any BuildThisPleaseAttestationProvider = DeviceCheckAttestationProvider()
    ) {
        self.config = configuration
        self.transport = transport
        self.credentials = credentialStore
        self.attestation = attestationProvider
        self.credentialPrefix = sha256(Data(configuration.projectKey.utf8)).base64URLEncodedString.prefix(16).description
    }

    public func configuration() async throws -> BuildThisPleaseConfigurationResponse {
        try await get("/v1/config")
    }

    public func requests() async throws -> [BuildThisPleaseTicket] {
        let page: BuildThisPleasePage<BuildThisPleaseTicket> = try await get("/v1/tickets?limit=100")
        return page.items
    }

    public func myRequests() async throws -> [BuildThisPleaseTicket] {
        let page: BuildThisPleasePage<BuildThisPleaseTicket> = try await get("/v1/me/tickets?limit=100")
        return page.items
    }

    public func implementedRequests() async throws -> [BuildThisPleaseTicket] {
        let page: BuildThisPleasePage<BuildThisPleaseTicket> = try await get("/v1/implemented?limit=100")
        return page.items
    }

    public func ticket(id: String) async throws -> BuildThisPleaseTicket {
        let envelope: TicketEnvelope = try await get("/v1/tickets/\(id)")
        return envelope.ticket
    }

    public func comments(ticketId: String) async throws -> [BuildThisPleaseComment] {
        let page: CommentPage = try await get("/v1/tickets/\(ticketId)/comments")
        return page.items
    }

    public func createTicket(title: String, description: String, idempotencyKey: String = UUID().uuidString) async throws -> BuildThisPleaseTicket {
        try await createTicket(title: title, description: description, email: nil, idempotencyKey: idempotencyKey)
    }

    public func createTicket(title: String, description: String, email: String?, idempotencyKey: String = UUID().uuidString) async throws -> BuildThisPleaseTicket {
        let envelope: TicketEnvelope = try await mutate("POST", path: "/v1/tickets", body: TicketBody(title: title, description: description, email: Self.normalizedOptional(email)?.lowercased()), idempotencyKey: idempotencyKey)
        return envelope.ticket
    }

    public func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket {
        let envelope: TicketEnvelope = try await mutate(voted ? "PUT" : "DELETE", path: "/v1/tickets/\(ticketId)/vote", bodyData: Data())
        return envelope.ticket
    }

    public func createComment(ticketId: String, body: String, idempotencyKey: String = UUID().uuidString) async throws -> BuildThisPleaseComment {
        let envelope: CommentEnvelope = try await mutate("POST", path: "/v1/tickets/\(ticketId)/comments", body: CommentBody(body: body), idempotencyKey: idempotencyKey)
        return envelope.comment
    }

    public func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment {
        let envelope: CommentEnvelope = try await mutate("PATCH", path: "/v1/tickets/\(ticketId)/comments/\(commentId)", body: CommentBody(body: body))
        return envelope.comment
    }

    public func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws {
        config.subscriptionStatus = status
        let _: EmptyResponse = try await mutate("PATCH", path: "/v1/installations/me/subscription-status", body: SubscriptionBody(status: status, observedAt: .now))
    }

    public func updateUserIdentity(revenueCatAppUserID: String?, email: String? = nil) async throws {
        let normalizedID = Self.normalizedOptional(revenueCatAppUserID)
        let normalizedEmail = Self.normalizedOptional(email)?.lowercased()
        let body = UserIdentityBody(revenueCatAppUserID: normalizedID, userEmail: normalizedEmail)
        let _: EmptyResponse = try await mutate("PATCH", path: "/v1/installations/me/user-identity", body: body)
        config.revenueCatAppUserID = normalizedID
        config.userEmail = normalizedEmail
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        let session = try await validSession()
        return try await perform("GET", path: path, bodyData: nil, token: session.token)
    }

    private func mutate<Response: Decodable, Body: Encodable>(_ method: String, path: String, body: Body, idempotencyKey: String? = nil) async throws -> Response {
        try await mutate(method, path: path, bodyData: try JSONCoding.encoder().encode(body), idempotencyKey: idempotencyKey)
    }

    private func mutate<Response: Decodable>(_ method: String, path: String, bodyData: Data, idempotencyKey: String? = nil) async throws -> Response {
        let session = try await validSession()
        var headers: [String: String] = [:]
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }
        if attestation.isSupported {
            guard let keyId = try await credentials.value(for: keyIdCredential) else { throw BuildThisPleaseError.attestationFailed }
            let bodyHash = sha256(bodyData).base64URLEncodedString
            let challengeBody = AssertionChallengeBody(method: method, path: path, bodyHash: bodyHash)
            let challengeData = try JSONCoding.encoder().encode(challengeBody)
            let challenge: AssertionChallenge = try await perform("POST", path: "/v1/attestation/assertions/challenges", bodyData: challengeData, token: session.token)
            let canonical = Data("BuildThisPlease/v1\n\(challenge.challengeHash)\n\(challenge.requestHash)".utf8)
            let assertion = try await attestation.generateAssertion(keyId, clientDataHash: sha256(canonical))
            headers["X-BTP-Attest-Challenge-ID"] = challenge.challengeId
            headers["X-BTP-App-Attest-Assertion"] = assertion.base64URLEncodedString
        }
        return try await perform(method, path: path, bodyData: bodyData, token: session.token, extraHeaders: headers)
    }

    private func validSession() async throws -> Session {
        if let memorySession, memorySession.expiresAt.timeIntervalSinceNow > 60 { return memorySession }
        if let dataString = try await credentials.value(for: sessionCredential),
           let data = dataString.data(using: .utf8),
           let stored = try? JSONCoding.decoder().decode(Session.self, from: data),
           stored.expiresAt.timeIntervalSinceNow > 60 {
            memorySession = stored
            return stored
        }
        if let sessionTask { return try await sessionTask.value }

        let task = Task { try await establishSession() }
        sessionTask = task
        defer { sessionTask = nil }

        let session = try await task.value
        memorySession = session
        let encoded = try JSONCoding.encoder().encode(session)
        try await credentials.set(String(decoding: encoded, as: UTF8.self), for: sessionCredential)
        return session
    }

    private func establishSession() async throws -> Session {
        if !attestation.isSupported {
            guard config.environment.permitsDevelopmentBypass else { throw BuildThisPleaseError.appAttestUnavailable }
            let body = registrationChallengeBody()
            let envelope: SessionEnvelope = try await perform("POST", path: "/v1/development/sessions", bodyData: try JSONCoding.encoder().encode(body), token: nil)
            return Session(token: envelope.sessionToken, installationId: envelope.installationId, expiresAt: envelope.expiresAt)
        }

        if let storedKeyId = try await credentials.value(for: keyIdCredential) {
            do { return try await recoverSession(keyId: storedKeyId) }
            catch let error as BuildThisPleaseError where shouldReplaceAttestationKey(after: error) {
                try await credentials.removeValue(for: keyIdCredential)
                try await credentials.removeValue(for: sessionCredential)
                memorySession = nil
            }
        }

        let body = registrationChallengeBody()
        let challenge: RegistrationChallenge = try await perform("POST", path: "/v1/attestation/challenges", bodyData: try JSONCoding.encoder().encode(body), token: nil)
        let keyId = try await attestation.generateKey()
        try await credentials.set(keyId, for: keyIdCredential)
        let attestationObject = try await attestation.attestKey(keyId, clientDataHash: sha256(Data(challenge.challenge.utf8)))
        let registration = RegistrationBody(challengeId: challenge.challengeId, keyId: keyId, attestationObject: attestationObject.base64URLEncodedString)
        let envelope: SessionEnvelope = try await perform("POST", path: "/v1/attestation/registrations", bodyData: try JSONCoding.encoder().encode(registration), token: nil)
        return Session(token: envelope.sessionToken, installationId: envelope.installationId, expiresAt: envelope.expiresAt)
    }

    private func recoverSession(keyId: String) async throws -> Session {
        let challengeBody = RecoveryChallengeBody(keyId: keyId)
        let challenge: AssertionChallenge = try await perform(
            "POST",
            path: "/v1/attestation/recovery/challenges",
            bodyData: try JSONCoding.encoder().encode(challengeBody),
            token: nil
        )
        let canonical = Data("BuildThisPlease/v1\n\(challenge.challengeHash)\n\(challenge.requestHash)".utf8)
        let assertion = try await attestation.generateAssertion(keyId, clientDataHash: sha256(canonical))
        let recovery = RecoveryBody(
            challengeId: challenge.challengeId,
            keyId: keyId,
            assertionObject: assertion.base64URLEncodedString
        )
        let envelope: SessionEnvelope = try await perform(
            "POST",
            path: "/v1/attestation/recoveries",
            bodyData: try JSONCoding.encoder().encode(recovery),
            token: nil
        )
        return Session(token: envelope.sessionToken, installationId: envelope.installationId, expiresAt: envelope.expiresAt)
    }

    private func registrationChallengeBody() -> RegistrationChallengeBody {
        RegistrationChallengeBody(
            bundleId: config.bundleIdentifier,
            environment: config.environment.attestationEnvironment,
            appVersion: config.appVersion,
            osVersion: config.osVersion,
            subscriptionStatus: config.subscriptionStatus,
            revenueCatAppUserId: config.revenueCatAppUserID,
            userEmail: config.userEmail
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func shouldReplaceAttestationKey(after error: BuildThisPleaseError) -> Bool {
        if case .server(let code, _, _) = error, code == "attestation_key_not_registered" {
            return true
        }
        guard case .local = config.environment,
              case .server(let code, _, _) = error
        else { return false }
        return [
            "invalid_assertion",
            "assertion_counter_replayed",
            "recovery_challenge_invalid"
        ].contains(code)
    }

    private func perform<Response: Decodable>(
        _ method: String,
        path: String,
        bodyData: Data?,
        token: String?,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: config.environment.baseURL)?.absoluteURL else {
            throw BuildThisPleaseError.invalidConfiguration(
                String(localized: "The API URL is invalid.", bundle: .module)
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.projectKey, forHTTPHeaderField: "X-BuildThisPlease-Project-Key")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let envelope = try? JSONCoding.decoder().decode(APIErrorEnvelope.self, from: data) {
                throw BuildThisPleaseError.server(code: envelope.error.code, message: envelope.error.message, status: response.statusCode)
            }
            throw BuildThisPleaseError.invalidResponse
        }
        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        do { return try JSONCoding.decoder().decode(Response.self, from: data) }
        catch { throw BuildThisPleaseError.invalidResponse }
    }

    private var sessionCredential: String { "\(credentialPrefix).session" }
    private var keyIdCredential: String { "\(credentialPrefix).appAttestKeyId" }
}

private struct EmptyResponse: Decodable {}
