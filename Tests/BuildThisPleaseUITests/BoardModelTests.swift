import BuildThisPleaseCore
import Foundation
import Testing
@testable import BuildThisPleaseUI

@Suite("Implemented request ordering")
struct BoardModelTests {
    @Test("Request email validation matches the Worker")
    func requestEmailValidation() {
        #expect(RequestEmailValidator.isValid(""))
        #expect(RequestEmailValidator.isValid("support@example.com"))
        #expect(!RequestEmailValidator.isValid("a@b"))
        #expect(!RequestEmailValidator.isValid("two..dots@example.com"))
    }

    @Test("Mine is hidden until the installation creates a request")
    @MainActor
    func mineVisibilityFollowsOwnedRequests() {
        let model = BoardModel(client: MockBuildThisPleaseClient(tickets: []))
        #expect(!model.showsMineSection)

        model.created(ticket(id: "owned", implementedAt: nil, updatedAt: .now, status: .pending))

        #expect(model.showsMineSection)
        #expect(model.selectedSection == .mine)
    }

    @Test("Newest implementation appears first with updated date as fallback")
    func newestImplementationAppearsFirst() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let tickets = [
            ticket(id: "older", implementedAt: reference.addingTimeInterval(-300), updatedAt: reference),
            ticket(id: "fallback", implementedAt: nil, updatedAt: reference.addingTimeInterval(-100)),
            ticket(id: "newest", implementedAt: reference, updatedAt: reference.addingTimeInterval(-500))
        ]

        #expect(tickets.sortedByImplementationRecency().map(\.id) == ["newest", "fallback", "older"])
    }

    @Test("Requests rank by votes then workflow progress")
    func requestsRankByVotesThenProgress() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let tickets = [
            ticket(id: "one-vote", implementedAt: nil, updatedAt: reference, status: .inProgress, voteCount: 1),
            ticket(id: "review", implementedAt: nil, updatedAt: reference, status: .inReview, voteCount: 5),
            ticket(id: "progress", implementedAt: nil, updatedAt: reference, status: .inProgress, voteCount: 5),
            ticket(id: "planned", implementedAt: nil, updatedAt: reference, status: .planned, voteCount: 5),
            ticket(id: "most-votes", implementedAt: nil, updatedAt: reference, status: .inReview, voteCount: 8)
        ]

        #expect(tickets.sortedByRequestPriority().map(\.id) == [
            "most-votes", "progress", "planned", "review", "one-vote"
        ])
    }

    private func ticket(
        id: String,
        implementedAt: Date?,
        updatedAt: Date,
        status: BuildThisPleaseTicketStatus = .implemented,
        voteCount: Int? = nil
    ) -> BuildThisPleaseTicket {
        BuildThisPleaseTicket(
            id: id,
            title: id,
            description: "Description",
            status: status,
            updatedAt: updatedAt,
            implementedAt: implementedAt,
            voteCount: voteCount
        )
    }
}
