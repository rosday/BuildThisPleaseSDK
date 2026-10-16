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
    private struct TicketEnvelope: Decodable, Sendable { let ticket: BuildThisPleaseTicket }
    private struct CommentEnvelope: Decodable, Sendable { let comment: BuildThisPleaseComment }
    private struct CommentPage: Decodable, Sendable { let items: [BuildThisPleaseComment] }
    private struct RegistrationChallenge: Codable, Sendable {
        let challengeId: String
        let challenge: String
        // Optional only to decode pending state saved by an older SDK.
        let expiresAt: Date?
    }
    private struct AssertionChallenge: Decodable { let challengeId: String; let challengeHash: String; let requestHash: String }
    private struct RegistrationBody: Encodable { let challengeId: String; let keyId: String; let attestationObject: String; let recoveryTokenHash: String }
    private struct RecoveryChallengeBody: Encodable { let keyId: String }
    private struct RecoveryBody: Encodable { let challengeId: String; let keyId: String; let assertionObject: String }
    private struct TicketBody: Encodable { let title: String; let description: String; let email: String?; let appVersion: String? }
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
    // Actor methods reenter at awaits; queue complete authenticated operations so a
    // mutation never pairs an old session with a replacement key or reorders counters.
    private var operationTail: Task<Void, Never>?

    private struct RecoveryCredential: Codable, Sendable {
        let token: String
        let installationId: String
        var enrolled: Bool
    }
    private struct PendingRegistration: Codable, Sendable {
        let keyId: String
        let recoveryToken: String
        var challenge: RegistrationChallenge?
        var attestationObject: String?
        var registrationAttempted = false
    }
    private struct ReplacementChallenge: Codable, Sendable {
        let operationId: String
        let challengeId: String
        let installationId: String
        let challenge: String
        let expiresAt: Date
    }
    private struct PendingReplacement: Codable, Sendable {
        let operationId: String
        let installationId: String
        let oldKeyId: String
        var oldProof: String
        var fallbackProof: String?
        let newKeyId: String
        let replacementRecoveryToken: String
        var challenge: ReplacementChallenge?
        var attestationObject: String?
    }
    private struct InstallationEnvelope: Decodable { let installationId: String }
    private struct RecoveryCredentialBody: Encodable { let recoveryTokenHash: String }
    private struct ReplacementChallengeBody: Encodable {
        let operationId: String
        let installationId: String
        let oldKeyId: String
        let newKeyId: String
        let replacementRecoveryTokenHash: String
    }
    private struct ReplacementBody: Encodable {
        let operationId: String
        let installationId: String
        let keyId: String
        let attestationObject: String
        let replacementRecoveryToken: String
    }

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
        let envelope: TicketEnvelope = try await mutate("POST", path: "/v1/tickets", body: TicketBody(title: title, description: description, email: Self.normalizedOptional(email)?.lowercased(), appVersion: Self.normalizedOptional(config.appVersion)), idempotencyKey: idempotencyKey)
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

    private func serialized<Response: Sendable>(
        _ operation: @escaping @Sendable (isolated BuildThisPleaseClient) async throws -> Response
    ) async throws -> Response {
        let previous = operationTail
        let task = Task {
            if let previous { await previous.value }
            try Task.checkCancellation()
            return try await operation(self)
        }
        operationTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func get<Response: Decodable & Sendable>(_ path: String) async throws -> Response {
        try await serialized { client in
            do {
                let session = try await client.validSession()
                return try await client.perform("GET", path: path, bodyData: nil, token: session.token)
            } catch where Self.isInvalidSession(error) {
                let session = try await client.validSession(forceRefresh: true)
                return try await client.perform("GET", path: path, bodyData: nil, token: session.token)
            }
        }
    }

    private func mutate<Response: Decodable & Sendable, Body: Encodable>(_ method: String, path: String, body: Body, idempotencyKey: String? = nil) async throws -> Response {
        try await mutate(method, path: path, bodyData: try JSONCoding.encoder().encode(body), idempotencyKey: idempotencyKey)
    }

    private func mutate<Response: Decodable & Sendable>(_ method: String, path: String, bodyData: Data, idempotencyKey: String? = nil) async throws -> Response {
        try await serialized { client in
            var session: Session?
            do {
                let established = try await client.validSession()
                session = established
                return try await client.mutateOnce(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey, session: established)
            } catch {
                if Self.isInvalidSession(error) {
                    let refreshed = try await client.validSession(forceRefresh: true)
                    return try await client.mutateOnce(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey, session: refreshed)
                }
                // The only automatic key replacement trigger is a native assertion
                // failure, before the business request has been sent.
                guard Self.isInvalidAssertionKey(error) else { throw error }
                let replacement = try await client.replaceKey(existingSession: session)
                return try await client.mutateOnce(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey, session: replacement)
            }
        }
    }

    private func mutateOnce<Response: Decodable>(_ method: String, path: String, bodyData: Data, idempotencyKey: String? = nil, session: Session) async throws -> Response {
        var headers: [String: String] = [:]
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }
        if attestation.isSupported {
            guard let keyId = try await credentials.value(for: keyIdCredential) else { throw BuildThisPleaseError.attestationFailed }
            let bodyHash = sha256(bodyData).base64URLEncodedString
            let challengeBody = AssertionChallengeBody(method: method, path: path, bodyHash: bodyHash)
            let challenge: AssertionChallenge = try await perform("POST", path: "/v1/attestation/assertions/challenges", bodyData: try JSONCoding.encoder().encode(challengeBody), token: session.token)
            let canonical = Data("BuildThisPlease/v1\n\(challenge.challengeHash)\n\(challenge.requestHash)".utf8)
            let assertion: Data
            do { assertion = try await attestation.generateAssertion(keyId, clientDataHash: sha256(canonical)) }
            catch where Self.isUnusableNativeKey(error) { throw InvalidAssertionKey(underlying: error) }
            headers["X-BTP-Attest-Challenge-ID"] = challenge.challengeId
            headers["X-BTP-App-Attest-Assertion"] = assertion.base64URLEncodedString
        }
        return try await perform(method, path: path, bodyData: bodyData, token: session.token, extraHeaders: headers)
    }

    private struct InvalidAssertionKey: Error { let underlying: any Error }
    private static func isInvalidAssertionKey(_ error: any Error) -> Bool { error is InvalidAssertionKey }
    private static func isInvalidSession(_ error: any Error) -> Bool {
        guard case BuildThisPleaseError.server(let code, _, let status) = error else { return false }
        return status == 401 && code == "installation_session_invalid"
    }
    private static func isUnusableNativeKey(_ error: any Error) -> Bool {
        let native = error as NSError
        return native.domain == "com.apple.devicecheck.error" && [2, 3].contains(native.code)
    }

    private func validSession(forceRefresh: Bool = false) async throws -> Session {
        // A persisted replacement always wins, including after a crash between
        // writing the new session and writing its matching key.
        if let pending: PendingReplacement = try await readCredential(pendingReplacementCredential) {
            return try await resumeReplacement(pending)
        }
        if let pending: PendingRegistration = try await readCredential(pendingRegistrationCredential) {
            let session = try await resumeRegistration(pending)
            return try await ensureRecoveryCredential(session)
        }
        if !forceRefresh, let memorySession, memorySession.expiresAt.timeIntervalSinceNow > 60 {
            return try await ensureRecoveryCredential(memorySession)
        }
        let stored: Session? = try await readCredential(sessionCredential)
        if !forceRefresh, let stored, stored.expiresAt.timeIntervalSinceNow > 60 {
            memorySession = stored
            return try await ensureRecoveryCredential(stored)
        }
        let session: Session
        if !attestation.isSupported {
            guard config.environment.permitsDevelopmentBypass else { throw BuildThisPleaseError.appAttestUnavailable }
            let envelope: SessionEnvelope = try await perform("POST", path: "/v1/development/sessions", bodyData: try JSONCoding.encoder().encode(registrationChallengeBody()), token: nil)
            session = Self.session(envelope)
            try await persistSession(session)
        } else if let keyId = try await credentials.value(for: keyIdCredential) {
            do {
                session = try await recoverSession(keyId: keyId)
                if let stored, stored.installationId != session.installationId { throw BuildThisPleaseError.invalidResponse }
                if let recovery: RecoveryCredential = try await readCredential(recoveryCredential), recovery.installationId != session.installationId { throw BuildThisPleaseError.invalidResponse }
                try await persistSession(session)
            } catch {
                guard Self.isInvalidAssertionKey(error) else { throw error }
                return try await replaceKey(existingSession: stored)
            }
        } else {
            // Never silently create another identity if any original proof remains.
            let recovery: RecoveryCredential? = try await readCredential(recoveryCredential)
            guard stored == nil, recovery == nil else { throw BuildThisPleaseError.attestationFailed }
            let pending = PendingRegistration(keyId: try await attestation.generateKey(), recoveryToken: Self.randomToken())
            try await writeCredential(pending, key: pendingRegistrationCredential)
            session = try await resumeRegistration(pending)
        }
        return try await ensureRecoveryCredential(session)
    }

    private func ensureRecoveryCredential(_ session: Session) async throws -> Session {
        guard attestation.isSupported else { return session }
        var recovery: RecoveryCredential
        if let stored: RecoveryCredential = try await readCredential(recoveryCredential) {
            guard stored.installationId == session.installationId else { throw BuildThisPleaseError.invalidResponse }
            if stored.enrolled { return session }
            recovery = stored
        } else {
            recovery = RecoveryCredential(token: Self.randomToken(), installationId: session.installationId, enrolled: false)
            // Save the secret before enrollment. A lost response can be retried.
            try await writeCredential(recovery, key: recoveryCredential)
        }
        let body = RecoveryCredentialBody(recoveryTokenHash: sha256(Data(recovery.token.utf8)).base64URLEncodedString)
        let envelope: InstallationEnvelope
        do {
            envelope = try await mutateOnce("POST", path: "/v1/installations/recovery-credential", bodyData: try JSONCoding.encoder().encode(body), session: session)
        } catch {
            guard Self.isInvalidAssertionKey(error) else { throw error }
            return try await replaceKey(existingSession: session)
        }
        guard envelope.installationId == session.installationId else { throw BuildThisPleaseError.invalidResponse }
        recovery.enrolled = true
        try await writeCredential(recovery, key: recoveryCredential)
        return session
    }

    private struct ExpiredInitialRegistration: Error {}

    private func hasEstablishedIdentity() async throws -> Bool {
        if memorySession != nil { return true }
        // Even malformed saved credentials are evidence of an existing identity.
        // Never replace an initial registration over any of them.
        for key in [keyIdCredential, sessionCredential, recoveryCredential, pendingReplacementCredential] {
            if try await credentials.value(for: key) != nil { return true }
        }
        return false
    }

    private func resumeRegistration(_ original: PendingRegistration, allowRestart: Bool = true) async throws -> Session {
        do {
            return try await continueRegistration(original)
        } catch {
            let unsavedAttestation = error is InvalidPendingAttestationKey && !original.registrationAttempted && original.attestationObject == nil
            let expiredAndUnregistered = error is ExpiredInitialRegistration
            guard allowRestart, unsavedAttestation || expiredAndUnregistered else { throw error }
            guard try await !hasEstablishedIdentity() else { throw BuildThisPleaseError.attestationFailed }
            // No request can have been submitted without a saved attestation.
            // Expired requests additionally require an explicit server lookup
            // proving that this initial key has not established an installation.
            let restarted = PendingRegistration(keyId: try await attestation.generateKey(), recoveryToken: original.recoveryToken)
            try await writeCredential(restarted, key: pendingRegistrationCredential)
            return try await resumeRegistration(restarted, allowRestart: false)
        }
    }

    private func registeredInitialSession(_ pending: PendingRegistration) async throws -> Session? {
        do {
            let recovered = try await recoverSession(keyId: pending.keyId)
            // A crash can leave both pending registration and partial active
            // credentials. They must refer to this same installation.
            if let stored: Session = try await readCredential(sessionCredential), stored.installationId != recovered.installationId { throw BuildThisPleaseError.invalidResponse }
            if let recovery: RecoveryCredential = try await readCredential(recoveryCredential), recovery.installationId != recovered.installationId { throw BuildThisPleaseError.invalidResponse }
            // The registration may have stored its key before recovery-token
            // enrollment or session issuance failed. A recovered key proves
            // identity, not that enrollment completed; confirm it explicitly.
            try await finishRegistration(pending, session: recovered, recoveryEnrolled: false)
            return recovered
        } catch let error as BuildThisPleaseError {
            guard case .server(let code, _, _) = error, code == "attestation_key_not_registered" else { throw error }
            return nil
        }
    }

    private func continueRegistration(_ original: PendingRegistration) async throws -> Session {
        var pending = original
        if try await hasEstablishedIdentity() {
            // Only a partial commit of this already-submitted registration can
            // legitimately coexist with active identity credentials.
            guard pending.registrationAttempted else { throw BuildThisPleaseError.attestationFailed }
            if let keyId = try await credentials.value(for: keyIdCredential), keyId != pending.keyId { throw BuildThisPleaseError.invalidResponse }
        }
        let challengeExpired = pending.challenge?.expiresAt.map { $0 <= .now } ?? false
        if pending.registrationAttempted || challengeExpired {
            // A lost accepted response must recover the original installation,
            // even when its now-used registration challenge has expired.
            if let recovered = try await registeredInitialSession(pending) { return recovered }
            guard try await !hasEstablishedIdentity() else { throw BuildThisPleaseError.attestationFailed }
            if challengeExpired { throw ExpiredInitialRegistration() }
        }
        if pending.challenge == nil {
            pending.challenge = try await perform("POST", path: "/v1/attestation/challenges", bodyData: try JSONCoding.encoder().encode(registrationChallengeBody()), token: nil)
            try await writeCredential(pending, key: pendingRegistrationCredential)
        }
        guard let challenge = pending.challenge else { throw BuildThisPleaseError.invalidResponse }
        if pending.attestationObject == nil {
            let object: Data
            do { object = try await attestation.attestKey(pending.keyId, clientDataHash: sha256(Data(challenge.challenge.utf8))) }
            catch where Self.isUnusableNativeKey(error) { throw InvalidPendingAttestationKey() }
            pending.attestationObject = object.base64URLEncodedString
            try await writeCredential(pending, key: pendingRegistrationCredential)
        }
        guard let object = pending.attestationObject else { throw BuildThisPleaseError.invalidResponse }
        pending.registrationAttempted = true
        try await writeCredential(pending, key: pendingRegistrationCredential)
        let registration = RegistrationBody(challengeId: challenge.challengeId, keyId: pending.keyId, attestationObject: object, recoveryTokenHash: sha256(Data(pending.recoveryToken.utf8)).base64URLEncodedString)
        let envelope: SessionEnvelope
        do {
            envelope = try await perform("POST", path: "/v1/attestation/registrations", bodyData: try JSONCoding.encoder().encode(registration), token: nil)
        } catch let error as BuildThisPleaseError {
            guard case .server(let code, _, _) = error, code == "attestation_challenge_invalid" else { throw error }
            // This response also covers a used challenge. Never infer absence
            // of an installation from it; look up and recover this key first.
            if let recovered = try await registeredInitialSession(pending) { return recovered }
            throw ExpiredInitialRegistration()
        }
        let session = Self.session(envelope)
        try await finishRegistration(pending, session: session)
        return session
    }

    private func finishRegistration(_ pending: PendingRegistration, session: Session, recoveryEnrolled: Bool = true) async throws {
        try await persistSession(session)
        try await credentials.set(pending.keyId, for: keyIdCredential)
        try await writeCredential(RecoveryCredential(token: pending.recoveryToken, installationId: session.installationId, enrolled: recoveryEnrolled), key: recoveryCredential)
        // With all active credentials durable, enrolled=false becomes the
        // pending enrollment phase. validSession confirms it using a full
        // assertion before returning any business result, and retries it after
        // failures without ever creating another installation.
        try await credentials.removeValue(for: pendingRegistrationCredential)
    }

    private func replaceKey(existingSession: Session?) async throws -> Session {
        if let pending: PendingReplacement = try await readCredential(pendingReplacementCredential) { return try await resumeReplacement(pending) }
        guard let oldKeyId = try await credentials.value(for: keyIdCredential) else { throw BuildThisPleaseError.attestationFailed }
        let recovery: RecoveryCredential? = try await readCredential(recoveryCredential)
        let installationId = existingSession?.installationId ?? recovery?.installationId
        let proof = recovery?.enrolled == true ? recovery?.token : existingSession?.token
        guard let installationId, let proof else { throw BuildThisPleaseError.attestationFailed }
        if let recovery, recovery.installationId != installationId { throw BuildThisPleaseError.invalidResponse }
        // An enrollment response can be lost after the backend accepted the saved
        // token. Keep that alternative proof without assuming enrollment succeeded.
        let fallbackProof = recovery?.enrolled == false ? recovery?.token : nil
        let pending = PendingReplacement(operationId: UUID().uuidString.lowercased(), installationId: installationId, oldKeyId: oldKeyId, oldProof: proof, fallbackProof: fallbackProof, newKeyId: try await attestation.generateKey(), replacementRecoveryToken: Self.randomToken())
        try await writeCredential(pending, key: pendingReplacementCredential)
        return try await resumeReplacement(pending)
    }

    private struct InvalidPendingAttestationKey: Error {}

    private func resumeReplacement(_ original: PendingReplacement, allowRestart: Bool = true) async throws -> Session {
        do {
            return try await continueReplacement(original)
        } catch {
            let expired: Bool
            if case BuildThisPleaseError.server(let code, _, _) = error { expired = code == "key_replacement_challenge_expired" }
            else { expired = false }
            guard allowRestart, expired || error is InvalidPendingAttestationKey else { throw error }
            // An explicit expiry is returned only for an uncompleted operation;
            // completed operations remain idempotently resumable. A native key
            // error here is wrapped only when no attestation object was saved,
            // so the completion request could not have been sent. Both cases
            // can safely retry with a new key while keeping the original identity.
            let restarted = PendingReplacement(operationId: UUID().uuidString.lowercased(), installationId: original.installationId, oldKeyId: original.oldKeyId, oldProof: original.oldProof, fallbackProof: original.fallbackProof, newKeyId: try await attestation.generateKey(), replacementRecoveryToken: Self.randomToken())
            try await writeCredential(restarted, key: pendingReplacementCredential)
            return try await resumeReplacement(restarted, allowRestart: false)
        }
    }

    private func continueReplacement(_ original: PendingReplacement) async throws -> Session {
        var pending = original
        if pending.challenge == nil {
            let body = ReplacementChallengeBody(operationId: pending.operationId, installationId: pending.installationId, oldKeyId: pending.oldKeyId, newKeyId: pending.newKeyId, replacementRecoveryTokenHash: sha256(Data(pending.replacementRecoveryToken.utf8)).base64URLEncodedString)
            let challenge: ReplacementChallenge
            do {
                challenge = try await perform("POST", path: "/v1/attestation/key-replacements/challenges", bodyData: try JSONCoding.encoder().encode(body), token: pending.oldProof)
            } catch let error as BuildThisPleaseError {
                guard case .server(let code, _, _) = error, code == "key_replacement_proof_invalid", let alternative = pending.fallbackProof else { throw error }
                pending.oldProof = alternative
                pending.fallbackProof = nil
                try await writeCredential(pending, key: pendingReplacementCredential)
                challenge = try await perform("POST", path: "/v1/attestation/key-replacements/challenges", bodyData: try JSONCoding.encoder().encode(body), token: pending.oldProof)
            }
            guard challenge.operationId == pending.operationId, challenge.challengeId == pending.operationId, challenge.installationId == pending.installationId else { throw BuildThisPleaseError.invalidResponse }
            pending.challenge = challenge
            try await writeCredential(pending, key: pendingReplacementCredential)
        }
        guard let challenge = pending.challenge else { throw BuildThisPleaseError.invalidResponse }
        if pending.attestationObject == nil {
            // In particular, DCError.serverUnavailable must retain this same key
            // and hash. Never replace the pending challenge on a retry.
            let object: Data
            do { object = try await attestation.attestKey(pending.newKeyId, clientDataHash: sha256(Data(challenge.challenge.utf8))) }
            catch where Self.isUnusableNativeKey(error) { throw InvalidPendingAttestationKey() }
            pending.attestationObject = object.base64URLEncodedString
            try await writeCredential(pending, key: pendingReplacementCredential)
        }
        guard let object = pending.attestationObject else { throw BuildThisPleaseError.invalidResponse }
        let body = ReplacementBody(operationId: pending.operationId, installationId: pending.installationId, keyId: pending.newKeyId, attestationObject: object, replacementRecoveryToken: pending.replacementRecoveryToken)
        let envelope: SessionEnvelope = try await perform("POST", path: "/v1/attestation/key-replacements", bodyData: try JSONCoding.encoder().encode(body), token: pending.oldProof)
        guard envelope.installationId == pending.installationId else { throw BuildThisPleaseError.invalidResponse }
        let session = Self.session(envelope)
        // Pending state stays in Keychain until every replacement credential is
        // durable, making crashes or partial write failures resumable.
        try await persistSession(session)
        try await credentials.set(pending.newKeyId, for: keyIdCredential)
        try await writeCredential(RecoveryCredential(token: pending.replacementRecoveryToken, installationId: pending.installationId, enrolled: true), key: recoveryCredential)
        try await credentials.removeValue(for: pendingReplacementCredential)
        return session
    }

    private func recoverSession(keyId: String) async throws -> Session {
        let challenge: AssertionChallenge = try await perform("POST", path: "/v1/attestation/recovery/challenges", bodyData: try JSONCoding.encoder().encode(RecoveryChallengeBody(keyId: keyId)), token: nil)
        let canonical = Data("BuildThisPlease/v1\n\(challenge.challengeHash)\n\(challenge.requestHash)".utf8)
        let assertion: Data
        do { assertion = try await attestation.generateAssertion(keyId, clientDataHash: sha256(canonical)) }
        catch where Self.isUnusableNativeKey(error) { throw InvalidAssertionKey(underlying: error) }
        let body = RecoveryBody(challengeId: challenge.challengeId, keyId: keyId, assertionObject: assertion.base64URLEncodedString)
        let envelope: SessionEnvelope = try await perform("POST", path: "/v1/attestation/recoveries", bodyData: try JSONCoding.encoder().encode(body), token: nil)
        return Self.session(envelope)
    }

    private static func session(_ envelope: SessionEnvelope) -> Session {
        Session(token: envelope.sessionToken, installationId: envelope.installationId, expiresAt: envelope.expiresAt)
    }
    private static func randomToken() -> String {
        var random = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }).base64URLEncodedString
    }
    private func persistSession(_ session: Session) async throws {
        try await writeCredential(session, key: sessionCredential)
        memorySession = session
    }
    private func readCredential<Value: Decodable>(_ key: String) async throws -> Value? {
        guard let value = try await credentials.value(for: key) else { return nil }
        // A malformed saved credential is evidence of an existing identity. Fail
        // closed rather than interpreting it as a first installation.
        return try JSONCoding.decoder().decode(Value.self, from: Data(value.utf8))
    }
    private func writeCredential<Value: Encodable>(_ value: Value, key: String) async throws {
        let encoded = try JSONCoding.encoder().encode(value)
        try await credentials.set(String(decoding: encoded, as: UTF8.self), for: key)
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
    private var recoveryCredential: String { "\(credentialPrefix).recoveryCredential" }
    private var pendingReplacementCredential: String { "\(credentialPrefix).pendingKeyReplacement" }
    private var pendingRegistrationCredential: String { "\(credentialPrefix).pendingRegistration" }
}

private struct EmptyResponse: Decodable, Sendable {}
