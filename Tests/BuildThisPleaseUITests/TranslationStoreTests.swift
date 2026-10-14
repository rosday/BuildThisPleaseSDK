import Foundation
import Testing
@testable import BuildThisPleaseUI

@Suite("Shared translation cache")
@MainActor
struct TranslationStoreTests {
    private let pair = TranslationStore.LanguagePair(source: "es", target: "en")

    @Test("A failed fallback string does not suppress unrelated strings in its batch")
    func isolatedFallbackFailure() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        let texts = ["Ya traducido", "Contenido problemático", "Otra solicitud"]
        store.enqueue(texts, pair: pair)
        let batch = try #require(store.claim(for: pair))
        let first = TranslationStore.Batch(id: batch.id, pair: pair, keys: [batch.keys[0]], texts: [batch.texts[0]])
        await store.complete(first, translations: ["Already translated"], provider: .translationFramework)
        var attempted: [String] = []
        await performTranslationFallback(batch, store: store) { text in
            attempted.append(text)
            return text == "Contenido problemático" ? nil : "Another request"
        }
        #expect(attempted == ["Contenido problemático", "Otra solicitud"])
        #expect(store.hasFailed(["Contenido problemático"], pair: pair))
        #expect(!store.hasFailed(["Otra solicitud"], pair: pair))
        #expect(store.result(for: ["Otra solicitud"], pair: pair)?.texts == ["Another request"])
        #expect(store.entry(for: texts[0], pair: pair)?.provider == .translationFramework)
    }

    @Test("Recreated views display cached text immediately and Show original stays respected")
    @available(iOS 18, macOS 15, *)
    func immediateCachedRendering() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        let target = DynamicTranslationState.targetLanguage.minimalIdentifier
        let localPair = TranslationStore.LanguagePair(source: "es", target: target)
        store.enqueue(["Hola"], pair: localPair)
        let batch = try #require(store.claim(for: localPair))
        await store.complete(batch, translations: ["Hello"], provider: .translationFramework)
        var state = DynamicTranslationState()
        #expect(state.text(at: 0, original: "Hola", texts: ["Hola"], store: store) == "Hello")
        state.showTranslation(for: ["Hola"])
        state.complete(["Hello"], provider: .translationFramework, requestID: state.requestID)
        state.showOriginal()
        #expect(state.text(at: 0, original: "Hola", texts: ["Hola"], store: store) == "Hola")
    }

    @Test("Identical text has distinct jobs and cache entries for each source language")
    func sourceLanguageIdentity() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        let english = TranslationStore.LanguagePair(source: "en", target: "es")
        let german = TranslationStore.LanguagePair(source: "de", target: "es")
        store.enqueue(["Gift"], pair: english)
        store.enqueue(["Gift"], pair: german)
        let englishBatch = try #require(store.claim(for: english))
        let germanBatch = try #require(store.claim(for: german))
        #expect(englishBatch.keys != germanBatch.keys)
        await store.complete(englishBatch, translations: ["Regalo"], provider: .translationFramework)
        await store.complete(germanBatch, translations: ["Veneno"], provider: .translationFramework)
        #expect(store.result(for: ["Gift"], pair: english)?.texts == ["Regalo"])
        #expect(store.result(for: ["Gift"], pair: german)?.texts == ["Veneno"])
    }

    @Test("Incomplete and failed groups render originals while retaining completed work")
    @available(iOS 18, macOS 15, *)
    func partialResultsDoNotBypassOriginalControl() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        let originals = ["Título de la solicitud", "Me gustaría guardar mis solicitudes para leerlas sin conexión."]
        let source = try #require(DynamicTranslationState.sourceLanguage(for: originals))
        let localPair = TranslationStore.LanguagePair(source: source, target: DynamicTranslationState.targetLanguage.minimalIdentifier)
        store.enqueue(originals, pair: localPair)
        let batch = try #require(store.claim(for: localPair))
        let first = TranslationStore.Batch(id: batch.id, pair: localPair, keys: [batch.keys[0]], texts: [batch.texts[0]])
        await store.complete(first, translations: ["Request title"], provider: .translationFramework)
        var state = DynamicTranslationState()
        #expect(state.text(at: 0, original: originals[0], texts: originals, store: store) == originals[0])
        state.showTranslation(for: originals)
        store.fail(batch)
        state.fail(requestID: state.requestID)
        #expect(state.text(at: 0, original: originals[0], texts: originals, store: store) == originals[0])
        #expect(store.entry(for: originals[0], pair: localPair)?.text == "Request title")
    }

    @Test("Warm cache rendering respects the current group and source language")
    @available(iOS 18, macOS 15, *)
    func warmCacheRequiresMatchingContext() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        let originals = ["Chat", "Keep the chat visible when I reopen the screen."]
        let foreign = TranslationStore.LanguagePair(source: "fr", target: DynamicTranslationState.targetLanguage.minimalIdentifier)
        store.enqueue(originals, pair: foreign)
        let batch = try #require(store.claim(for: foreign))
        await store.complete(batch, translations: ["Cat", "Wrong description"], provider: .translationFramework)
        let state = DynamicTranslationState()
        #expect(state.text(at: 0, original: originals[0], texts: originals, store: store) == "Chat")
    }

    @Test("List and detail share translations and request only missing strings")
    func sharedResultsAndDeduplication() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        store.enqueue(["Título", "Descripción"], pair: pair)
        store.enqueue(["Título", "Descripción", "Nota"], pair: pair)
        let batch = try #require(store.claim(for: pair))
        #expect(batch.texts == ["Título", "Descripción", "Nota"])
        #expect(store.claim(for: pair) == nil)

        await store.complete(batch, translations: ["Title", "Description", "Note"], provider: .translationFramework)
        #expect(store.result(for: ["Título", "Descripción"], pair: pair)?.texts == ["Title", "Description"])
        #expect(store.result(for: ["Título", "Descripción", "Nota"], pair: pair)?.texts == ["Title", "Description", "Note"])
        store.enqueue(["Título", "Texto nuevo"], pair: pair)
        #expect(store.claim(for: pair)?.texts == ["Texto nuevo"])
    }

    @Test("Canceled work can resume and late results cannot overwrite a newer batch")
    func cancellationAndStaleCompletion() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        store.enqueue(["Hola"], pair: pair)
        let oldBatch = try #require(store.claim(for: pair))
        store.cancel(oldBatch)
        let resumed = try #require(store.claim(for: pair))
        await store.complete(oldBatch, translations: ["Stale"], provider: .foundationModel)
        #expect(store.result(for: ["Hola"], pair: pair) == nil)
        await store.complete(resumed, translations: ["Hello"], provider: .translationFramework)
        #expect(store.result(for: ["Hola"], pair: pair)?.texts == ["Hello"])
        #expect(!store.hasFailed(["Hola"], pair: pair))
    }

    @Test("Navigating away retains streamed results and resumes only unfinished strings")
    func partialCompletionSurvivesCancellation() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        store.enqueue(["Título", "Descripción"], pair: pair)
        let batch = try #require(store.claim(for: pair))
        let first = TranslationStore.Batch(id: batch.id, pair: pair, keys: [batch.keys[0]], texts: [batch.texts[0]])
        await store.complete(first, translations: ["Title"], provider: .translationFramework)
        #expect(store.remaining(batch)?.texts == ["Descripción"])
        store.cancel(batch)
        #expect(store.entry(for: "Título", pair: pair)?.text == "Title")
        #expect(store.claim(for: pair)?.texts == ["Descripción"])
    }

    @Test("Translations survive a new store and stay isolated by text and target language")
    func diskRestorationAndCacheIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translations.json")
        let store = TranslationStore(fileURL: file)
        await store.prepare()
        store.enqueue(["Hola"], pair: pair)
        let batch = try #require(store.claim(for: pair))
        await store.complete(batch, translations: ["Hello"], provider: .foundationModel)

        let restored = TranslationStore(fileURL: file)
        async let firstLoad: Void = restored.prepare()
        async let secondLoad: Void = restored.prepare()
        _ = await (firstLoad, secondLoad)
        #expect(restored.result(for: ["Hola"], pair: pair)?.texts == ["Hello"])
        #expect(restored.result(for: ["Hola"], pair: pair)?.provider == .foundationModel)
        #expect(restored.result(for: ["Hola editado"], pair: pair) == nil)
        #expect(restored.result(for: ["Hola"], pair: .init(source: "es", target: "fr")) == nil)
        restored.enqueue(["Hola"], pair: pair)
        #expect(restored.claim(for: pair) == nil)

        let data = try Data(contentsOf: file)
        let entries = try JSONDecoder().decode([String: TranslationStore.Entry].self, from: data)
        let expired = entries.mapValues {
            TranslationStore.Entry(text: $0.text, provider: $0.provider,
                                   createdAt: .now.addingTimeInterval(-TranslationStore.lifetime - 1))
        }
        try JSONEncoder().encode(expired).write(to: file)
        let afterExpiry = TranslationStore(fileURL: file)
        await afterExpiry.prepare()
        #expect(afterExpiry.result(for: ["Hola"], pair: pair) == nil)
    }

    @Test("Invalid results remain retryable and a corrupt cache does not block translation")
    func failureAndCorruptCache() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("invalid JSON".utf8).write(to: file)
        let store = TranslationStore(fileURL: file)
        await store.prepare()
        store.enqueue(["Hola"], pair: pair)
        let batch = try #require(store.claim(for: pair))
        await store.complete(batch, translations: [""], provider: .translationFramework)
        #expect(store.hasFailed(["Hola"], pair: pair))
        #expect(store.result(for: ["Hola"], pair: pair) == nil)
        store.enqueue(["Hola"], pair: pair)
        #expect(store.claim(for: pair) == nil)
        store.enqueue(["Hola"], pair: pair, retry: true)
        let retry = try #require(store.claim(for: pair))
        await store.complete(retry, translations: ["Hello"], provider: .translationFramework)
        #expect(!store.hasFailed(["Hola"], pair: pair))
    }

    @Test("Cache and batch sizes remain bounded")
    func boundedCache() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        let texts = (0..<(TranslationStore.maximumEntries + 25)).map { "Texto \($0)" }
        store.enqueue(texts, pair: pair)
        while let batch = store.claim(for: pair) {
            #expect(batch.texts.count <= 24)
            await store.complete(batch, translations: batch.texts.map { "Translated \($0)" }, provider: .translationFramework)
        }
        let cached = texts.filter { store.entry(for: $0, pair: pair) != nil }
        #expect(cached.count == TranslationStore.maximumEntries)
        #expect(cached.last == texts.last)
    }

    @Test("An active group can requeue a field evicted while another field was in flight")
    func evictionDuringPartialCompletion() async throws {
        let store = TranslationStore(fileURL: nil)
        await store.prepare()
        let originals = ["Título", "Descripción"]
        store.enqueue(originals, pair: pair)
        let batch = try #require(store.claim(for: pair))
        let first = TranslationStore.Batch(id: batch.id, pair: pair, keys: [batch.keys[0]], texts: [batch.texts[0]])
        await store.complete(first, translations: ["Title"], provider: .translationFramework)
        store.enqueue((0..<TranslationStore.maximumEntries).map { "Otro texto \($0)" }, pair: pair)
        while let filler = store.claim(for: pair) {
            await store.complete(filler, translations: filler.texts, provider: .translationFramework)
        }
        #expect(store.entry(for: originals[0], pair: pair) == nil)
        let second = try #require(store.remaining(batch))
        await store.complete(second, translations: ["Description"], provider: .translationFramework)
        #expect(store.result(for: originals, pair: pair) == nil)
        store.enqueue(originals, pair: pair)
        let retry = try #require(store.claim(for: pair))
        #expect(retry.texts == ["Título"])
        await store.complete(retry, translations: ["Title"], provider: .translationFramework)
        #expect(store.result(for: originals, pair: pair)?.texts == ["Title", "Description"])
    }
}
