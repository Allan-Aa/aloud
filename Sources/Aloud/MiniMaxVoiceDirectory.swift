import CryptoKit
import Foundation

enum MiniMaxVoiceKind: String, CaseIterable, Codable, Sendable {
    case system
    case cloned
    case generated
}

struct MiniMaxVoiceCandidate: Equatable, Hashable, Sendable {
    let kind: MiniMaxVoiceKind
    let wireID: String
    let displayName: String?
}

struct MiniMaxVoiceDescriptor: Equatable, Hashable, Sendable {
    let stableID: VoiceID
    let wireID: String
    let displayName: String
    let kind: MiniMaxVoiceKind
}

struct MiniMaxVoiceDirectoryOperation: Equatable, Sendable {
    let revision: UUID
    fileprivate let nonce: UUID
    fileprivate let publication: ProviderAccountEvidenceStore.PublicationToken?
}

actor MiniMaxVoiceDirectory {
    private let publicationStore: ProviderAccountEvidenceStore?
    private var currentOperation: MiniMaxVoiceDirectoryOperation?
    private var publishedRevision: UUID?
    private var byRevision: [UUID: [VoiceID: MiniMaxVoiceDescriptor]] = [:]

    init(publicationStore: ProviderAccountEvidenceStore? = nil) {
        self.publicationStore = publicationStore
    }

    func begin(revision: UUID) -> MiniMaxVoiceDirectoryOperation {
        let operation = MiniMaxVoiceDirectoryOperation(
            revision: revision, nonce: UUID(), publication: nil
        )
        if publicationStore == nil { currentOperation = operation }
        return operation
    }

    func begin(
        revision: UUID,
        publication: ProviderAccountEvidenceStore.PublicationToken
    ) -> MiniMaxVoiceDirectoryOperation? {
        guard let publicationStore, publicationStore.isCurrent(publication) else { return nil }
        if let currentGeneration = currentOperation?.publication?.generation,
           currentGeneration > publication.generation {
            return nil
        }
        let operation = MiniMaxVoiceDirectoryOperation(
            revision: revision, nonce: UUID(), publication: publication
        )
        currentOperation = operation
        return operation
    }

    func commit(
        _ candidates: [MiniMaxVoiceCandidate],
        operation: MiniMaxVoiceDirectoryOperation
    ) -> [MiniMaxVoiceDescriptor]? {
        guard currentOperation == operation, !Task.isCancelled else { return nil }
        if let publication = operation.publication,
           publicationStore?.isCurrent(publication) != true {
            currentOperation = nil
            return nil
        }
        let descriptors = descriptorsByID(for: candidates)
        guard currentOperation == operation, !Task.isCancelled else { return nil }
        if let publication = operation.publication,
           publicationStore?.isCurrent(publication) != true {
            currentOperation = nil
            return nil
        }
        if publicationStore != nil {
            currentOperation = nil
            return Self.sorted(Array(descriptors.values))
        }
        byRevision[operation.revision] = descriptors
        publishedRevision = operation.revision
        currentOperation = nil
        return Self.sorted(Array(descriptors.values))
    }

    func descriptors(revision: UUID) async -> [MiniMaxVoiceDescriptor] {
        if let publicationStore,
           let descriptors = await publicationStore.miniMaxVoiceDescriptors(revision: revision) {
            return descriptors
        }
        return Self.sorted(Array((byRevision[revision] ?? Self.fallbackDescriptors).values))
    }

    func containsInCurrentCatalog(_ stableID: VoiceID) async -> Bool {
        if let publicationStore {
            return await publicationStore.miniMaxCurrentCatalogContains(stableID)
        }
        guard let publishedRevision else { return false }
        return byRevision[publishedRevision]?[stableID] != nil
    }

    func resolve(_ stableID: VoiceID, revision: UUID) async -> MiniMaxWireVoice? {
        if let publicationStore,
           let descriptor = await publicationStore.miniMaxVoiceDescriptor(
               stableID, revision: revision
           ) {
            return MiniMaxWireVoice(voiceID: descriptor.wireID, emotion: nil)
        }
        guard let descriptor = byRevision[revision]?[stableID] ?? Self.fallbackDescriptors[stableID] else { return nil }
        return MiniMaxWireVoice(voiceID: descriptor.wireID, emotion: nil)
    }

    private func descriptorsByID(for candidates: [MiniMaxVoiceCandidate]) -> [VoiceID: MiniMaxVoiceDescriptor] {
        var descriptors = Self.fallbackDescriptors
        for candidate in candidates.sorted(by: Self.precedes) where descriptors.values.contains(where: { $0.wireID == candidate.wireID }) == false {
            let stableID = VoiceID(rawValue: "minimax.dynamic.\(Self.digest(for: candidate))")
            descriptors[stableID] = MiniMaxVoiceDescriptor(
                stableID: stableID,
                wireID: candidate.wireID,
                displayName: candidate.displayName?.isEmpty == false ? candidate.displayName! : candidate.wireID,
                kind: candidate.kind
            )
        }
        return descriptors
    }

    private static let fallbackDescriptors: [VoiceID: MiniMaxVoiceDescriptor] = [
        VoiceID(rawValue: "minimax.radio-host.default"): .init(
            stableID: VoiceID(rawValue: "minimax.radio-host.default"),
            wireID: "Chinese (Mandarin)_Radio_Host",
            displayName: "中文 · 电台主播",
            kind: .system
        ),
        VoiceID(rawValue: "minimax.laid-back-girl.default"): .init(
            stableID: VoiceID(rawValue: "minimax.laid-back-girl.default"),
            wireID: "Chinese (Mandarin)_Laid_BackGirl",
            displayName: "中文 · 慵懒少女",
            kind: .system
        ),
    ]

    private static func precedes(_ lhs: MiniMaxVoiceCandidate, _ rhs: MiniMaxVoiceCandidate) -> Bool {
        let lhsKey = (priority(of: lhs.kind), lhs.wireID, lhs.displayName ?? "")
        let rhsKey = (priority(of: rhs.kind), rhs.wireID, rhs.displayName ?? "")
        return lhsKey < rhsKey
    }

    private static func priority(of kind: MiniMaxVoiceKind) -> Int {
        switch kind {
        case .system: 0
        case .cloned: 1
        case .generated: 2
        }
    }

    private static func sorted(
        _ descriptors: [MiniMaxVoiceDescriptor]
    ) -> [MiniMaxVoiceDescriptor] {
        descriptors.sorted { lhs, rhs in
            let lhsKey = (priority(of: lhs.kind), lhs.wireID, lhs.stableID.rawValue)
            let rhsKey = (priority(of: rhs.kind), rhs.wireID, rhs.stableID.rawValue)
            return lhsKey < rhsKey
        }
    }

    private static func digest(for candidate: MiniMaxVoiceCandidate) -> String {
        SHA256.hash(data: Data("\(candidate.kind.rawValue)\u{0}\(candidate.wireID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
