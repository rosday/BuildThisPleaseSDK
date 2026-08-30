import BuildThisPleaseCore
import Foundation
import Observation

@Observable
@MainActor
final class BoardModel {
    enum Section: String, CaseIterable, Identifiable { case requests, mine, implemented; var id: String { rawValue } }
    let client: any BuildThisPleaseClientProtocol
    var selectedSection: Section = .requests
    var requests: [BuildThisPleaseTicket] = []
    var mine: [BuildThisPleaseTicket] = []
    var implemented: [BuildThisPleaseTicket] = []
    var isLoading = false
    var errorMessage: String?
    var votingTicketIDs: Set<String> = []
    var selectedTicket: BuildThisPleaseTicket?
    var presentsCreate = false

    init(client: any BuildThisPleaseClientProtocol) { self.client = client }

    var currentTickets: [BuildThisPleaseTicket] {
        switch selectedSection { case .requests: requests; case .mine: mine; case .implemented: implemented }
    }

    var showsMineSection: Bool { !mine.isEmpty }

    func load() async {
        guard !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        do {
            async let requests = client.requests()
            async let mine = client.myRequests()
            async let implemented = client.implementedRequests()
            let loaded = try await (requests, mine, implemented)
            self.requests = loaded.0.sortedByRequestPriority()
            setMine(loaded.1)
            self.implemented = loaded.2.sortedByImplementationRecency()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshCurrentSection() async {
        do {
            switch selectedSection {
            case .requests: requests = try await client.requests().sortedByRequestPriority()
            case .mine: setMine(try await client.myRequests())
            case .implemented: implemented = try await client.implementedRequests().sortedByImplementationRecency()
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func created(_ ticket: BuildThisPleaseTicket) {
        mine.insert(ticket, at: 0)
        selectedSection = .mine
    }

    func toggleVote(_ ticket: BuildThisPleaseTicket) async {
        guard ticket.voteCount != nil, votingTicketIDs.insert(ticket.id).inserted else { return }
        defer { votingTicketIDs.remove(ticket.id) }
        do {
            let updated = try await client.setVote(ticketId: ticket.id, voted: !(ticket.hasVoted ?? false))
            replace(updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func replace(_ ticket: BuildThisPleaseTicket) {
        requests = requests.map { $0.id == ticket.id ? ticket : $0 }.sortedByRequestPriority()
        mine = mine.map { $0.id == ticket.id ? ticket : $0 }
        implemented = implemented.map { $0.id == ticket.id ? ticket : $0 }.sortedByImplementationRecency()
    }

    private func setMine(_ tickets: [BuildThisPleaseTicket]) {
        mine = tickets
        if mine.isEmpty && selectedSection == .mine {
            selectedSection = .requests
        }
    }
}

extension Array where Element == BuildThisPleaseTicket {
    func sortedByRequestPriority() -> Self {
        sorted {
            let leftVotes = $0.voteCount ?? 0
            let rightVotes = $1.voteCount ?? 0
            if leftVotes != rightVotes { return leftVotes > rightVotes }

            let leftProgress = $0.status.requestProgressRank
            let rightProgress = $1.status.requestProgressRank
            if leftProgress != rightProgress { return leftProgress > rightProgress }

            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    func sortedByImplementationRecency() -> Self {
        sorted {
            let leftDate = $0.implementedAt ?? $0.updatedAt
            let rightDate = $1.implementedAt ?? $1.updatedAt
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id > $1.id
        }
    }
}

private extension BuildThisPleaseTicketStatus {
    var requestProgressRank: Int {
        switch self {
        case .inProgress: 3
        case .planned: 2
        case .inReview: 1
        default: 0
        }
    }
}

@Observable
@MainActor
final class TicketDetailModel {
    let client: any BuildThisPleaseClientProtocol
    var ticket: BuildThisPleaseTicket
    var comments: [BuildThisPleaseComment] = []
    var reply = ""
    var isLoading = false
    var isSending = false
    var isVoting = false
    var errorMessage: String?
    var editingComment: BuildThisPleaseComment?
    let onTicketUpdated: (BuildThisPleaseTicket) -> Void
    private var replyIdempotencyKey = UUID().uuidString

    init(
        client: any BuildThisPleaseClientProtocol,
        ticket: BuildThisPleaseTicket,
        onTicketUpdated: @escaping (BuildThisPleaseTicket) -> Void
    ) {
        self.client = client
        self.ticket = ticket
        self.onTicketUpdated = onTicketUpdated
    }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            async let refreshed = client.ticket(id: ticket.id)
            async let messages = client.comments(ticketId: ticket.id)
            (ticket, comments) = try await (refreshed, messages)
            onTicketUpdated(ticket)
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    func toggleVote() async {
        guard !isVoting else { return }
        isVoting = true
        defer { isVoting = false }
        do {
            ticket = try await client.setVote(ticketId: ticket.id, voted: !(ticket.hasVoted ?? false))
            onTicketUpdated(ticket)
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    func sendReply() async {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true; defer { isSending = false }
        do { let comment = try await client.createComment(ticketId: ticket.id, body: trimmed, idempotencyKey: replyIdempotencyKey); comments.append(comment); reply = ""; replyIdempotencyKey = UUID().uuidString; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func updateComment(_ comment: BuildThisPleaseComment, body: String) async -> Bool {
        do {
            let updated = try await client.updateComment(ticketId: ticket.id, commentId: comment.id, body: body)
            comments = comments.map { $0.id == updated.id ? updated : $0 }
            editingComment = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
