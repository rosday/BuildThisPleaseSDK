import CryptoKit
import Foundation
import Observation

/// Shared by the SDK's screens. UI state stays on the main actor; disk I/O uses its own actor.
@Observable
@MainActor
final class TranslationStore {
    static let shared = TranslationStore()
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maximumEntries = 500

    struct Entry: Codable, Sendable {
        let text: String
        let provider: DynamicTranslationState.Provider
        let createdAt: Date
    }

    struct LanguagePair: Hashable, Sendable {
        let source: String
        let target: String
    }

    struct Batch {
        let id: UUID
        let pair: LanguagePair
        let keys: [String]
        let texts: [String]
    }

    private struct Job {
        let text: String
        let pair: LanguagePair
        let order: Int
        var batchID: UUID?
    }

    private(set) var revision = 0
    private var entries: [String: Entry] = [:]
    private var jobs: [String: Job] = [:]
    private var failures: Set<String> = []
    private var nextOrder = 0
    private var didLoad = false
    private var loadTask: Task<[String: Entry], Never>?
    private let disk: TranslationDiskCache

    init(fileURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("BuildThisPlease/translations-v2.json")) {
        disk = TranslationDiskCache(fileURL: fileURL)
    }

    func prepare() async {
        guard !didLoad else { return }
        if loadTask == nil {
            // The store owns this one-time load so a disappearing row cannot cancel it.
            loadTask = Task { await disk.load() }
        }
        let loaded = await loadTask!.value
        guard !didLoad else { return }
        entries.merge(loaded) { current, _ in current }
        prune()
        didLoad = true
        loadTask = nil
        revision &+= 1
    }

    var languagePairs: [LanguagePair] {
        Array(Set(jobs.values.map(\.pair))).sorted {
            ($0.source, $0.target) < ($1.source, $1.target)
        }
    }

    func enqueue(_ texts: [String], pair: LanguagePair, retry: Bool = false) {
        var changed = false
        for text in texts where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = Self.key(text, pair: pair)
            guard entry(for: text, pair: pair) == nil, jobs[key] == nil else { continue }
            if retry { failures.remove(key) }
            guard !failures.contains(key) else { continue }
            jobs[key] = Job(text: text, pair: pair, order: nextOrder)
            nextOrder &+= 1
            changed = true
        }
        if changed { revision &+= 1 }
    }

    func entry(for text: String, pair: LanguagePair) -> Entry? {
        guard let entry = entries[Self.key(text, pair: pair)],
              Date.now.timeIntervalSince(entry.createdAt) < Self.lifetime else { return nil }
        return entry
    }

    func result(for texts: [String], pair: LanguagePair) -> (texts: [String], provider: DynamicTranslationState.Provider)? {
        var translations: [String] = []
        var provider = DynamicTranslationState.Provider.translationFramework
        for text in texts {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translations.append(text)
                continue
            }
            guard let entry = entry(for: text, pair: pair) else { return nil }
            translations.append(entry.text)
            if entry.provider == .foundationModel { provider = .foundationModel }
        }
        return (translations, provider)
    }

    func hasFailed(_ texts: [String], pair: LanguagePair) -> Bool {
        texts.contains { failures.contains(Self.key($0, pair: pair)) }
    }

    func hasQueuedWork(for pair: LanguagePair) -> Bool {
        jobs.values.contains { $0.pair == pair && $0.batchID == nil }
    }

    func claim(for pair: LanguagePair) -> Batch? {
        let pending = jobs.filter { $0.value.pair == pair && $0.value.batchID == nil }
            .sorted { $0.value.order < $1.value.order }.prefix(24)
        guard !pending.isEmpty else { return nil }
        let id = UUID()
        for (key, _) in pending { jobs[key]?.batchID = id }
        return Batch(id: id, pair: pair, keys: pending.map(\.key), texts: pending.map { $0.value.text })
    }

    func remaining(_ batch: Batch) -> Batch? {
        let indices = batch.keys.indices.filter { jobs[batch.keys[$0]]?.batchID == batch.id }
        guard !indices.isEmpty else { return nil }
        return Batch(id: batch.id, pair: batch.pair,
                     keys: indices.map { batch.keys[$0] }, texts: indices.map { batch.texts[$0] })
    }

    func complete(_ batch: Batch, translations: [String], provider: DynamicTranslationState.Provider) async {
        guard translations.count == batch.keys.count,
              translations.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            fail(batch)
            return
        }
        for (key, text) in zip(batch.keys, translations) where jobs[key]?.batchID == batch.id {
            entries[key] = Entry(text: text, provider: provider, createdAt: .now)
            jobs.removeValue(forKey: key)
            failures.remove(key)
        }
        prune()
        revision &+= 1
        await disk.save(entries, revision: revision)
    }

    func fail(_ batch: Batch) {
        for key in batch.keys where jobs[key]?.batchID == batch.id {
            jobs.removeValue(forKey: key)
            failures.insert(key)
        }
        revision &+= 1
    }

    func cancel(_ batch: Batch) {
        for key in batch.keys where jobs[key]?.batchID == batch.id {
            jobs[key]?.batchID = nil
        }
        revision &+= 1
    }

    private func prune() {
        entries = entries.filter { Date.now.timeIntervalSince($0.value.createdAt) < Self.lifetime }
        if entries.count > Self.maximumEntries {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted {
                $0.value.createdAt > $1.value.createdAt
            }.prefix(Self.maximumEntries).map { ($0.key, $0.value) })
        }
    }

    private static func key(_ text: String, pair: LanguagePair) -> String {
        // Length-prefixing avoids ambiguous text/language boundaries. Originals are not persisted.
        let input = Data("\(pair.source.utf8.count):\(pair.source)\(pair.target.utf8.count):\(pair.target)\(text)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

private actor TranslationDiskCache {
    let fileURL: URL?
    private var savedRevision = -1
    private let maximumBytes = 2 * 1024 * 1024

    init(fileURL: URL?) { self.fileURL = fileURL }

    func load() -> [String: TranslationStore.Entry] {
        guard let fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: TranslationStore.Entry].self, from: data)
        else { return [:] }
        return entries
    }

    func save(_ entries: [String: TranslationStore.Entry], revision: Int) {
        guard let fileURL, revision > savedRevision else { return }
        // Retain the newest results while also bounding the disk footprint for long feedback.
        var bounded = entries
        while let data = try? JSONEncoder().encode(bounded) {
            if data.count <= maximumBytes {
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: fileURL, options: .atomic)
                    savedRevision = revision
                } catch { /* Translation remains available in memory if the cache cannot be written. */ }
                return
            }
            guard let oldest = bounded.min(by: { $0.value.createdAt < $1.value.createdAt })?.key else { return }
            bounded.removeValue(forKey: oldest)
        }
    }
}
