import BuildThisPleaseCore
import Foundation
import Testing
@testable import BuildThisPleaseUI

@Suite("Dynamic translation")
@MainActor
struct DynamicTranslationTests {
    @Test("A canceled worker ending cannot clear its replacement's activity")
    func replacementWorkerOwnership() {
        var activity = TranslationWorkerActivity()
        let old = activity.begin()
        let replacement = activity.begin()
        activity.end(old)
        #expect(activity.taskID == replacement)
        activity.end(replacement)
        #expect(activity.taskID == nil)
    }

    @Test("Preloading covers the exact card and detail groups when their source languages differ")
    func preloadUsesRenderedGroups() {
        let ticket = BuildThisPleaseTicket(
            id: "implemented",
            title: "Export",
            description: "Please let us export all of our saved requests to a file. This would make it much easier to keep a backup, read them on another device, and share our feedback with other members of the team.",
            status: .implemented,
            implementationNote: "Ahora puedes exportar todas tus solicitudes. Guarda una copia y compártela con tu equipo."
        )
        #expect(DynamicTranslationState.sourceLanguage(for: ticket.cardTranslationTexts) == "es")
        #expect(DynamicTranslationState.sourceLanguage(for: ticket.detailTranslationTexts) == "en")
        let groups = [ticket, ticket].translationTextGroups
        #expect(groups == [ticket.cardTranslationTexts, ticket.detailTranslationTexts])
        let forEnglish = groups.filter {
            guard let source = DynamicTranslationState.sourceLanguage(for: $0) else { return false }
            return DynamicTranslationState.languagesDiffer(sourceIdentifier: source, target: Locale.Language(identifier: "en"))
        }
        #expect(forEnglish == [ticket.cardTranslationTexts])
    }

    @Test("Language comparison ignores regions but preserves Chinese scripts")
    func languageComparison() {
        #expect(!DynamicTranslationState.languagesDiffer(
            sourceIdentifier: "en-US",
            target: Locale.Language(identifier: "en-GB")
        ))
        #expect(DynamicTranslationState.languagesDiffer(
            sourceIdentifier: "es",
            target: Locale.Language(identifier: "en")
        ))
        #expect(DynamicTranslationState.languagesDiffer(
            sourceIdentifier: "zh-Hans",
            target: Locale.Language(identifier: "zh-Hant")
        ))
        #expect(!DynamicTranslationState.languagesDiffer(
            sourceIdentifier: "zh-Hant",
            target: Locale.Language(identifier: "zh-Hant")
        ))
    }

    @Test("A translation result is accepted only for the active request")
    func requestIdentityPreventsStaleResults() {
        let originals = ["Título", "Descripción"]
        var state = DynamicTranslationState()

        state.showTranslation(for: originals)
        let activeRequestID = state.requestID
        state.complete(["Title", "Description"], provider: .translationFramework, requestID: activeRequestID - 1)
        #expect(!state.isShowingTranslation(for: originals))

        state.complete(["Title", "Description"], provider: .translationFramework, requestID: activeRequestID)
        #expect(state.isShowingTranslation(for: originals))
        #expect(state.text(at: 0, original: originals[0]) == "Title")
        #expect(!state.isAITranslation(for: originals))
    }

    @Test("Automatic translation runs once per source text")
    func automaticTranslationRequestLifecycle() {
        let originals = ["Hola"]
        var state = DynamicTranslationState()

        #expect(state.needsTranslation(for: originals))
        state.showTranslation(for: originals)
        let requestID = state.requestID
        #expect(!state.needsTranslation(for: originals))

        state.complete(["Hello"], provider: .foundationModel, requestID: requestID)
        #expect(state.isAITranslation(for: originals))
        #expect(state.hasTranslation(for: originals))
        #expect(!state.needsTranslation(for: originals))
        #expect(state.text(at: 0, original: originals[0]) == "Hello")

        state.showOriginal()
        #expect(state.text(at: 0, original: originals[0]) == "Hola")
        #expect(!state.needsTranslation(for: originals))

        state.showCachedTranslation()
        #expect(state.text(at: 0, original: originals[0]) == "Hello")
        #expect(state.requestID == requestID)

        #expect(state.needsTranslation(for: ["Adiós"]))
    }

    @Test("Failed translations can be retried")
    func failedTranslationRetry() {
        let originals = ["Hola"]
        var state = DynamicTranslationState()

        state.showTranslation(for: originals)
        let failedRequestID = state.requestID
        state.fail(requestID: failedRequestID)

        #expect(state.hasFailed(for: originals))
        #expect(state.showsStatus(for: originals))
        #expect(!state.needsTranslation(for: originals))

        state.showTranslation(for: originals)

        #expect(state.isTranslating(originals))
        #expect(!state.hasFailed(for: originals))
        #expect(state.requestID == failedRequestID + 1)
    }

    @Test("Canceled translations retry when the view task restarts")
    func canceledTranslationRetry() {
        let originals = ["Hola"]
        var state = DynamicTranslationState()

        state.showTranslation(for: originals)
        state.cancel(requestID: state.requestID)

        #expect(!state.hasFailed(for: originals))
        #expect(state.needsTranslation(for: originals))
    }
}
