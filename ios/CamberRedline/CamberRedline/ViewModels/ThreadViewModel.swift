import Foundation
import Observation
import Supabase

enum NoteTargetType: String, Codable {
    case sms
    case span
    case call
}

struct NoteEntry: Identifiable, Hashable, Codable {
    let targetType: NoteTargetType
    let targetId: String
    var text: String
    var updatedAt: Date

    var id: String {
        "\(targetType.rawValue):\(targetId)"
    }
}

@MainActor
@Observable
final class ThreadViewModel {

    // MARK: - Published State

    var currentContact: Contact?
    var threadItems: [ThreadItem] = []
    var isLoading = false
    var isLoadingOlderThread = false
    var hasOlderThreadItems = false
    var error: String?
    var notesByTarget: [String: NoteEntry] = [:]
    var reviewProjects: [ReviewProject] = []
    var contactSequence: [Contact] = []
    var truthGraphStatus: TruthGraphResponse?
    var truthGraphInteractionId: String?
    var isTruthGraphLoading = false
    var truthGraphError: String?

    var isAttributionWritesLocked: Bool {
        bootstrapService.writeLockState != nil
    }

    var attributionWritesLockedBannerText: String? {
        bootstrapService.writesLockedBannerText
    }

    // MARK: - Dependencies

    private let service = SupabaseService.shared
    private let bootstrapService = BootstrapService.shared
    private let notesStorageKey = "redline_thread_notes_v1"
    private var gradeChannel: RealtimeChannelV2?
    private var gradeInsertTask: Task<Void, Never>?
    private var gradeUpdateTask: Task<Void, Never>?
    private var subscribedContactId: UUID?
    private var threadInteractionsChannel: RealtimeChannelV2?
    private var threadInteractionsTask: Task<Void, Never>?
    private var threadInteractionsUpdateTask: Task<Void, Never>?
    private var threadSMSChannel: RealtimeChannelV2?
    private var threadSMSTask: Task<Void, Never>?
    private var threadSMSUpdateTask: Task<Void, Never>?
    private var threadReviewQueueChannel: RealtimeChannelV2?
    private var threadReviewQueueTask: Task<Void, Never>?
    private var threadReviewQueueUpdateTask: Task<Void, Never>?
    private var threadRealtimeReloadTask: Task<Void, Never>?
    private var threadFallbackRefreshTask: Task<Void, Never>?
    private var postResolveRefreshTask: Task<Void, Never>?
    private var projectRefreshLoopTask: Task<Void, Never>?
    private var transientErrorTask: Task<Void, Never>?
    private let threadPageSize = 20
    private var currentThreadOffset = 0
    private var totalThreadCount = 0

    init() {
        loadPersistedNotes()
    }

    // MARK: - Shared Context / Warmup

    func updateContactSequence(_ contacts: [Contact]) {
        contactSequence = contacts
    }

    func warmProjectPickerCache() async {
        await loadReviewProjectsIfNeeded()
        startProjectRefreshLoopIfNeeded()
    }

    func prefetchNextContact(after contactId: UUID) {
        guard !contactSequence.isEmpty else { return }
        guard let currentIndex = contactSequence.firstIndex(where: { $0.contactId == contactId }) else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < contactSequence.count else { return }
        let nextContact = contactSequence[nextIndex]
        Task {
            await service.prefetchThread(
                contactId: nextContact.contactId,
                limit: threadPageSize,
                offset: 0
            )
        }
    }

    // MARK: - Load Thread

    func loadThread(contactId: UUID) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        truthGraphStatus = nil
        truthGraphInteractionId = nil
        truthGraphError = nil
        defer { isLoading = false }

        currentThreadOffset = 0
        totalThreadCount = 0
        hasOlderThreadItems = false
        await loadThreadPage(contactId: contactId, offset: 0, resetItems: true)
        prefetchNextContact(after: contactId)
    }

    func loadTruthGraphStatusIfNeeded(interactionId: String, force: Bool = false) async {
        let trimmed = interactionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !force,
           truthGraphInteractionId == trimmed,
           truthGraphStatus != nil
        {
            return
        }

        guard !isTruthGraphLoading else { return }
        isTruthGraphLoading = true
        truthGraphError = nil
        truthGraphInteractionId = trimmed
        defer { isTruthGraphLoading = false }

        do {
            truthGraphStatus = try await service.fetchTruthGraph(interactionId: trimmed)
        } catch {
            truthGraphError = error.localizedDescription
        }
    }

    func loadOlderThreadPageIfNeeded() async {
        guard let contactId = currentContact?.contactId else { return }
        guard hasOlderThreadItems, !isLoadingOlderThread else { return }

        isLoadingOlderThread = true
        defer { isLoadingOlderThread = false }

        let nextOffset = currentThreadOffset + threadPageSize
        await loadThreadPage(contactId: contactId, offset: nextOffset, resetItems: false)
    }

    private func loadThreadPage(contactId: UUID, offset: Int, resetItems: Bool) async {
        do {
            let response = try await service.fetchThread(
                contactId: contactId,
                limit: threadPageSize,
                offset: offset
            )
            let pageItems = makeThreadItems(from: response)

            if resetItems {
                threadItems = pageItems
            } else {
                let existingIDs = Set(threadItems.map(\.id))
                let uniqueOlderItems = pageItems.filter { !existingIDs.contains($0.id) }
                threadItems = uniqueOlderItems + threadItems
            }

            currentThreadOffset = offset
            totalThreadCount = response.pagination.total
            hasOlderThreadItems = (offset + response.pagination.limit) < totalThreadCount
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makeThreadItems(from response: ThreadResponse) -> [ThreadItem] {
        var items: [ThreadItem] = []

        for item in normalizedThreadItems(from: response.thread) {
            switch item {
            case .call(let entry):
                let allClaims = entry.allClaims
                let header = CallHeaderEntry(
                    interactionId: entry.interactionId,
                    eventAt: entry.eventAt,
                    contactName: entry.contactName,
                    direction: entry.direction,
                    channel: entry.channel,
                    summary: entry.summary,
                    claims: allClaims,
                    spans: entry.spans,
                    pendingAttributionCount: entry.pendingAttributionCount
                )
                items.append(.callHeader(header))

                let transcript: String
                if let raw = entry.rawTranscript, !raw.isEmpty {
                    transcript = raw
                } else {
                    transcript = entry.spans
                        .sorted { $0.spanIndex < $1.spanIndex }
                        .compactMap(\.transcriptSegment)
                        .joined(separator: "\n")
                }

                if !transcript.isEmpty {
                    let turns = TranscriptParser.parse(
                        transcript,
                        contactName: response.contact.name
                    )
                    for turn in turns {
                        items.append(.speakerTurn(turn))
                    }
                }

            case .sms(let entry):
                items.append(.sms(entry))

            default:
                items.append(item)
            }
        }

        return items
    }

    private func normalizedThreadItems(from rawItems: [RawThreadItem]) -> [ThreadItem] {
        var normalized: [ThreadItem] = []
        var callIndexByInteraction: [String: Int] = [:]
        var seenSMSIds = Set<String>()

        for raw in rawItems {
            guard let item = raw.toThreadItem() else { continue }

            switch item {
            case .call(let entry):
                if entry.interactionId.hasPrefix("cll_SHADOW_") {
                    continue
                }

                if let existingIndex = callIndexByInteraction[entry.interactionId],
                   case .call(let existingEntry) = normalized[existingIndex]
                {
                    normalized[existingIndex] = .call(
                        mergeCallEntries(existingEntry, entry)
                    )
                } else {
                    callIndexByInteraction[entry.interactionId] = normalized.count
                    normalized.append(.call(entry))
                }

            case .sms(let entry):
                guard seenSMSIds.insert(entry.messageId).inserted else { continue }
                normalized.append(.sms(entry))

            case .speakerTurn, .callHeader:
                continue
            }
        }

        return normalized
    }

    private func mergeCallEntries(_ lhs: CallEntry, _ rhs: CallEntry) -> CallEntry {
        let mergedClaims = mergeClaims(lhs.claims ?? [], rhs.claims ?? [])

        return CallEntry(
            interactionId: lhs.interactionId,
            eventAt: preferredText(lhs.eventAt, rhs.eventAt) ?? lhs.eventAt,
            contactName: preferredText(lhs.contactName, rhs.contactName),
            direction: preferredText(lhs.direction, rhs.direction),
            channel: preferredText(lhs.channel, rhs.channel),
            summary: preferredText(lhs.summary, rhs.summary),
            rawTranscript: preferredText(lhs.rawTranscript, rhs.rawTranscript),
            participants: mergeUniqueStrings(lhs.participants, rhs.participants),
            spans: mergeSpans(lhs.spans, rhs.spans),
            pendingAttributionCount: max(lhs.pendingAttributionCount, rhs.pendingAttributionCount),
            claims: mergedClaims.isEmpty ? nil : mergedClaims
        )
    }

    private func mergeClaims(_ lhs: [ClaimEntry], _ rhs: [ClaimEntry]) -> [ClaimEntry] {
        var merged = lhs
        var seen = Set(lhs.map(\.claimId))

        for claim in rhs where seen.insert(claim.claimId).inserted {
            merged.append(claim)
        }

        return merged
    }

    private func mergeSpans(_ lhs: [SpanEntry], _ rhs: [SpanEntry]) -> [SpanEntry] {
        var mergedById: [UUID: SpanEntry] = [:]
        var order: [UUID] = []

        for span in lhs + rhs {
            if let existing = mergedById[span.spanId] {
                mergedById[span.spanId] = preferredSpan(existing, span)
            } else {
                mergedById[span.spanId] = span
                order.append(span.spanId)
            }
        }

        return order
            .compactMap { mergedById[$0] }
            .sorted { $0.spanIndex < $1.spanIndex }
    }

    private func preferredSpan(_ lhs: SpanEntry, _ rhs: SpanEntry) -> SpanEntry {
        spanScore(lhs) >= spanScore(rhs) ? lhs : rhs
    }

    private func spanScore(_ span: SpanEntry) -> Int {
        var score = 0
        if let transcriptSegment = span.transcriptSegment, !transcriptSegment.isEmpty {
            score += 100 + min(transcriptSegment.count, 500)
        }
        if span.reviewQueueId != nil {
            score += 20
        }
        if span.needsAttribution {
            score += 5
        }
        score += span.claims.count * 2
        return score
    }

    private func mergeUniqueStrings(_ lhs: [String], _ rhs: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()

        for value in lhs + rhs {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalized.isEmpty { continue }
            guard seen.insert(normalized).inserted else { continue }
            merged.append(value)
        }

        return merged
    }

    private func preferredText(_ lhs: String?, _ rhs: String?) -> String? {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (left, right) {
        case let (.some(l), .some(r)):
            if l.count == r.count {
                return l >= r ? l : r
            }
            return l.count >= r.count ? l : r
        case let (.some(l), .none):
            return l
        case let (.none, .some(r)):
            return r
        case (.none, .none):
            return nil
        }
    }

    // MARK: - Grade Claim

    func gradeClaim(
        claimId: UUID,
        grade: GradeType,
        correctionText: String? = nil
    ) async {
        guard let contactId = currentContact?.contactId else {
            error = "No contact selected"
            return
        }
        self.error = nil

        do {
            try await service.gradeClaimViaAPI(
                claimId: claimId,
                grade: grade.rawValue,
                correctionText: correctionText,
                gradedBy: "ios_reviewer"
            )
            await loadThread(contactId: contactId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Attribution Resolve

    func loadReviewProjectsIfNeeded() async {
        if !reviewProjects.isEmpty {
            refreshReviewProjectsInBackgroundIfNeeded()
            return
        }

        let cached = bootstrapService.snapshotCachedReviewProjects()
        if !cached.isEmpty {
            reviewProjects = cached
        }

        do {
            let fetchedProjects = try await bootstrapService.fetchReviewProjects(forceRefresh: reviewProjects.isEmpty)
            reviewProjects = fetchedProjects
            if reviewProjects.isEmpty {
                showTransientError("No projects available yet.")
            } else {
                error = nil
            }
        } catch {
            if reviewProjects.isEmpty {
                showTransientError("Failed to load projects: \(error.localizedDescription)")
            }
        }

        refreshReviewProjectsInBackgroundIfNeeded()
    }

    @discardableResult
    func resolveAttribution(
        reviewQueueId: String,
        projectId: String,
        notes: String? = nil,
        reloadAfterResolve: Bool = true
    ) async -> Bool {
        if let banner = bootstrapService.writesLockedBannerText {
            showTransientError(banner, clearAfter: .seconds(4))
            return false
        }

        error = nil
        do {
            _ = try await bootstrapService.resolve(
                queueId: reviewQueueId,
                projectId: projectId,
                notes: notes,
                userId: "ios_redline"
            )
            if reloadAfterResolve {
                schedulePostResolveSync()
            }
            return true
        } catch {
            if let banner = bootstrapService.writesLockedBannerText {
                showTransientError(banner, clearAfter: .seconds(4))
            } else {
                showTransientError("Attribution update failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    @discardableResult
    func resolveAttributions(reviewQueueIds: [String], projectId: String, notes: String? = nil) async -> Bool {
        if let banner = bootstrapService.writesLockedBannerText {
            showTransientError(banner, clearAfter: .seconds(4))
            return false
        }

        var seen = Set<String>()
        let uniqueQueueIds = reviewQueueIds.filter { seen.insert($0).inserted }
        guard !uniqueQueueIds.isEmpty else { return true }

        do {
            for queueId in uniqueQueueIds {
                _ = try await bootstrapService.resolve(
                    queueId: queueId,
                    projectId: projectId,
                    notes: notes,
                    userId: "ios_redline"
                )
            }
            schedulePostResolveSync()
            return true
        } catch {
            if let banner = bootstrapService.writesLockedBannerText {
                showTransientError(banner, clearAfter: .seconds(4))
            } else {
                showTransientError("Attribution update failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    @discardableResult
    func dismissAttribution(
        reviewQueueId: String,
        reason: String? = nil,
        notes: String? = nil,
        reloadAfterResolve: Bool = true
    ) async -> Bool {
        if let banner = bootstrapService.writesLockedBannerText {
            showTransientError(banner, clearAfter: .seconds(4))
            return false
        }

        error = nil
        do {
            _ = try await bootstrapService.dismiss(
                queueId: reviewQueueId,
                reason: reason,
                notes: notes,
                userId: "ios_redline"
            )
            if reloadAfterResolve {
                schedulePostResolveSync()
            }
            return true
        } catch {
            if let banner = bootstrapService.writesLockedBannerText {
                showTransientError(banner, clearAfter: .seconds(4))
            } else {
                showTransientError("Attribution update failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    @discardableResult
    func dismissAttributions(reviewQueueIds: [String], reason: String? = nil, notes: String? = nil) async -> Bool {
        if let banner = bootstrapService.writesLockedBannerText {
            showTransientError(banner, clearAfter: .seconds(4))
            return false
        }

        var seen = Set<String>()
        let uniqueQueueIds = reviewQueueIds.filter { seen.insert($0).inserted }
        guard !uniqueQueueIds.isEmpty else { return true }

        do {
            for queueId in uniqueQueueIds {
                _ = try await bootstrapService.dismiss(
                    queueId: queueId,
                    reason: reason,
                    notes: notes,
                    userId: "ios_redline"
                )
            }
            schedulePostResolveSync()
            return true
        } catch {
            if let banner = bootstrapService.writesLockedBannerText {
                showTransientError(banner, clearAfter: .seconds(4))
            } else {
                showTransientError("Attribution update failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    // MARK: - Attribution Undo

    @discardableResult
    func undoAttribution(reviewQueueId: String, reloadAfterUndo: Bool = true) async -> Bool {
        if let banner = bootstrapService.writesLockedBannerText {
            showTransientError(banner, clearAfter: .seconds(4))
            return false
        }

        error = nil
        do {
            try await bootstrapService.undo(queueId: reviewQueueId)
            if reloadAfterUndo {
                schedulePostResolveSync()
            }
            return true
        } catch {
            if let banner = bootstrapService.writesLockedBannerText {
                showTransientError(banner, clearAfter: .seconds(4))
            } else {
                showTransientError("Undo failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    private func schedulePostResolveSync() {
        postResolveRefreshTask?.cancel()
        postResolveRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let contactId = self.currentContact?.contactId else { return }
            self.service.invalidateThreadCache(for: contactId)
            await self.loadThread(contactId: contactId)
            NotificationCenter.default.post(name: .redlineAttributionDidResolve, object: nil)
        }
    }

    private func refreshReviewProjectsInBackgroundIfNeeded() {
        let cacheAge = bootstrapService.reviewProjectsCacheAge() ?? .infinity
        guard cacheAge >= 5 * 60 else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await self.bootstrapService.fetchReviewProjects(forceRefresh: true)
                if !refreshed.isEmpty {
                    self.reviewProjects = refreshed
                }
            } catch {
                // Keep current in-memory list if refresh fails.
            }
        }
    }

    private func startProjectRefreshLoopIfNeeded() {
        guard projectRefreshLoopTask == nil else { return }
        projectRefreshLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                do {
                    let refreshed = try await self.bootstrapService.fetchReviewProjects(forceRefresh: true)
                    if !refreshed.isEmpty {
                        self.reviewProjects = refreshed
                    }
                } catch {
                    // Keep running; next refresh may succeed.
                }
            }
        }
    }

    func showTransientError(_ message: String, clearAfter: Duration = .seconds(2)) {
        error = message
        transientErrorTask?.cancel()
        transientErrorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: clearAfter)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if self.error == message {
                self.error = nil
            }
        }
    }

    // MARK: - Realtime (claim_grades)

    func startClaimGradeSubscription(contactId: UUID) async {
        if subscribedContactId == contactId, gradeChannel != nil {
            return
        }

        await stopClaimGradeSubscription()

        let channel = service.client.channel("claim-grades-\(contactId.uuidString.lowercased())")
        gradeChannel = channel
        subscribedContactId = contactId

        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "claim_grades"
        )
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "claim_grades"
        )

        do {
            try await channel.subscribeWithError()
        } catch {
            if shouldIgnoreRealtimeError(error) {
                return
            }
            print("Claim grade realtime unavailable: \(error.localizedDescription)")
            await stopClaimGradeSubscription()
            return
        }
        error = nil

        gradeInsertTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await insert in inserts {
                self.mergeGrade(from: insert)
            }
        }

        gradeUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in updates {
                self.mergeGrade(from: update)
            }
        }
    }

    func stopClaimGradeSubscription() async {
        gradeInsertTask?.cancel()
        gradeInsertTask = nil

        gradeUpdateTask?.cancel()
        gradeUpdateTask = nil

        subscribedContactId = nil

        if let channel = gradeChannel {
            gradeChannel = nil
            await service.client.removeChannel(channel)
        }
    }

    private static let realtimeDecoder = JSONDecoder()

    private func mergeGrade(from action: InsertAction) {
        guard
            let record = try? action.decodeRecord(
                as: RealtimeGradeRecord.self,
                decoder: Self.realtimeDecoder
            )
        else { return }

        applyGradeUpdate(record)
    }

    private func mergeGrade(from action: UpdateAction) {
        guard
            let record = try? action.decodeRecord(
                as: RealtimeGradeRecord.self,
                decoder: Self.realtimeDecoder
            )
        else { return }

        applyGradeUpdate(record)
    }

    private func applyGradeUpdate(_ record: RealtimeGradeRecord) {
        threadItems = threadItems.map { item in
            guard case .callHeader(let header) = item else { return item }

            let updatedClaims = header.claims.map { claim in
                guard claim.claimId == record.claimId else { return claim }
                return ClaimEntry(
                    claimId: claim.claimId,
                    claimType: claim.claimType,
                    claimText: claim.claimText,
                    grade: record.grade ?? claim.grade,
                    correctionText: record.correctionText ?? claim.correctionText,
                    gradedBy: record.gradedBy ?? claim.gradedBy
                )
            }

            return .callHeader(
                CallHeaderEntry(
                    interactionId: header.interactionId,
                    eventAt: header.eventAt,
                    contactName: header.contactName,
                    direction: header.direction,
                    channel: header.channel,
                    summary: header.summary,
                    claims: updatedClaims,
                    spans: header.spans,
                    pendingAttributionCount: header.pendingAttributionCount
                )
            )
        }
    }

    // MARK: - Realtime (interactions for current thread)

    func startInteractionsSubscription(contactId: UUID) async {
        await stopInteractionsSubscription()

        let interactionsChannel = service.client.channel("thread-interactions-\(contactId.uuidString.lowercased())")
        threadInteractionsChannel = interactionsChannel

        let interactionInserts = interactionsChannel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "interactions"
        )
        let interactionUpdates = interactionsChannel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "interactions"
        )

        let smsChannel = service.client.channel("thread-sms-\(contactId.uuidString.lowercased())")
        threadSMSChannel = smsChannel
        let smsInserts = smsChannel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "sms_messages"
        )
        let smsUpdates = smsChannel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "sms_messages"
        )
        let reviewQueueChannel = service.client.channel("thread-review-queue-\(contactId.uuidString.lowercased())")
        let reviewQueueInserts = reviewQueueChannel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "review_queue"
        )
        let reviewQueueUpdates = reviewQueueChannel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "review_queue"
        )

        do {
            try await interactionsChannel.subscribeWithError()
            try await smsChannel.subscribeWithError()
        } catch {
            if !shouldIgnoreRealtimeError(error) {
                print("Thread interactions realtime unavailable: \(error.localizedDescription)")
            }
            await stopInteractionsSubscription()
            startThreadFallbackRefresh(contactId: contactId)
            return
        }
        stopThreadFallbackRefresh()
        do {
            try await reviewQueueChannel.subscribeWithError()
            threadReviewQueueChannel = reviewQueueChannel
        } catch {
            if !shouldIgnoreRealtimeError(error) {
                print("Thread review_queue realtime unavailable: \(error.localizedDescription)")
            }
            await service.client.removeChannel(reviewQueueChannel)
        }

        threadInteractionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await insert in interactionInserts {
                guard let record = try? insert.decodeRecord(
                    as: RealtimeInteractionRecord.self,
                    decoder: Self.realtimeDecoder
                ) else { continue }
                guard record.contactId == self.currentContact?.contactId else { continue }
                self.scheduleThreadReload(contactId: contactId)
            }
        }

        threadInteractionsUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in interactionUpdates {
                guard let record = try? update.decodeRecord(
                    as: RealtimeInteractionRecord.self,
                    decoder: Self.realtimeDecoder
                ) else { continue }
                guard record.contactId == self.currentContact?.contactId else { continue }
                self.scheduleThreadReload(contactId: contactId)
            }
        }

        threadSMSTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await insert in smsInserts {
                guard let record = try? insert.decodeRecord(
                    as: RealtimeSMSRecord.self,
                    decoder: Self.realtimeDecoder
                ) else { continue }
                guard self.smsRecordMatchesCurrentContact(record) else { continue }
                self.scheduleThreadReload(contactId: contactId)
            }
        }

        threadSMSUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in smsUpdates {
                guard let record = try? update.decodeRecord(
                    as: RealtimeSMSRecord.self,
                    decoder: Self.realtimeDecoder
                ) else { continue }
                guard self.smsRecordMatchesCurrentContact(record) else { continue }
                self.scheduleThreadReload(contactId: contactId)
            }
        }

        if threadReviewQueueChannel != nil {
            threadReviewQueueTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await insert in reviewQueueInserts {
                    guard let record = try? insert.decodeRecord(
                        as: RealtimeReviewQueueRecord.self,
                        decoder: Self.realtimeDecoder
                    ) else { continue }
                    guard self.reviewQueueRecordMatchesCurrentThread(record) else { continue }
                    self.scheduleThreadReload(contactId: contactId)
                }
            }

            threadReviewQueueUpdateTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await update in reviewQueueUpdates {
                    guard let record = try? update.decodeRecord(
                        as: RealtimeReviewQueueRecord.self,
                        decoder: Self.realtimeDecoder
                    ) else { continue }
                    guard self.reviewQueueRecordMatchesCurrentThread(record) else { continue }
                    self.scheduleThreadReload(contactId: contactId)
                }
            }
        }
    }

    func stopInteractionsSubscription() async {
        threadInteractionsTask?.cancel()
        threadInteractionsTask = nil

        threadInteractionsUpdateTask?.cancel()
        threadInteractionsUpdateTask = nil

        threadSMSTask?.cancel()
        threadSMSTask = nil

        threadSMSUpdateTask?.cancel()
        threadSMSUpdateTask = nil

        threadReviewQueueTask?.cancel()
        threadReviewQueueTask = nil

        threadReviewQueueUpdateTask?.cancel()
        threadReviewQueueUpdateTask = nil

        threadRealtimeReloadTask?.cancel()
        threadRealtimeReloadTask = nil
        stopThreadFallbackRefresh()

        if let channel = threadInteractionsChannel {
            threadInteractionsChannel = nil
            await service.client.removeChannel(channel)
        }

        if let channel = threadSMSChannel {
            threadSMSChannel = nil
            await service.client.removeChannel(channel)
        }

        if let channel = threadReviewQueueChannel {
            threadReviewQueueChannel = nil
            await service.client.removeChannel(channel)
        }
    }

    private func scheduleThreadReload(contactId: UUID) {
        threadRealtimeReloadTask?.cancel()
        threadRealtimeReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self.currentContact?.contactId == contactId else { return }
            guard !self.isLoading, !self.isLoadingOlderThread else { return }
            await self.loadThread(contactId: contactId)
        }
    }

    private func startThreadFallbackRefresh(contactId: UUID) {
        guard threadFallbackRefreshTask == nil else { return }
        threadFallbackRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard self.currentContact?.contactId == contactId else { break }
                guard self.currentThreadOffset == 0 else { continue }
                guard !self.isLoading, !self.isLoadingOlderThread else { continue }
                await self.loadThread(contactId: contactId)
            }
        }
    }

    private func stopThreadFallbackRefresh() {
        threadFallbackRefreshTask?.cancel()
        threadFallbackRefreshTask = nil
    }

    private func smsRecordMatchesCurrentContact(_ record: RealtimeSMSRecord) -> Bool {
        guard let contact = currentContact else { return false }

        let recordPhone = normalizedPhone(record.contactPhone)
        let contactPhone = normalizedPhone(contact.phone)
        if !recordPhone.isEmpty, !contactPhone.isEmpty, recordPhone == contactPhone {
            return true
        }

        let recordName = (record.contactName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contactName = contact.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !recordName.isEmpty, !contactName.isEmpty, recordName == contactName {
            return true
        }

        return false
    }

    private func reviewQueueRecordMatchesCurrentThread(_ record: RealtimeReviewQueueRecord) -> Bool {
        guard let contact = currentContact else { return false }
        if threadItems.isEmpty {
            return true
        }

        if let interactionId = record.interactionId, !interactionId.isEmpty {
            if interactionId.hasPrefix("sms_thread_") {
                let suffix = interactionId.dropFirst("sms_thread_".count)
                let smsThreadPhone = String(suffix.split(separator: "_").first ?? "")
                    .filter(\.isWholeNumber)
                let contactPhone = normalizedPhone(contact.phone)
                if !smsThreadPhone.isEmpty, !contactPhone.isEmpty, smsThreadPhone.hasSuffix(contactPhone) {
                    return true
                }
            }

            if threadItems.contains(where: { item in
                guard case .callHeader(let header) = item else { return false }
                return header.interactionId == interactionId
            }) {
                return true
            }
        }

        if let spanId = record.spanId {
            if threadItems.contains(where: { item in
                guard case .callHeader(let header) = item else { return false }
                return header.spans.contains(where: { $0.spanId == spanId })
            }) {
                return true
            }
        }

        return record.interactionId == nil && record.spanId == nil
    }

    private func normalizedPhone(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let digits = raw.filter(\.isWholeNumber)
        if digits.count >= 10 {
            return String(digits.suffix(10))
        }
        return digits
    }

    private func shouldIgnoreRealtimeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("cancellationerror") || message.contains("cancelled")
    }

    // MARK: - Notes

    func noteText(targetType: NoteTargetType, targetId: String) -> String {
        notesByTarget[noteKey(targetType: targetType, targetId: targetId)]?.text ?? ""
    }

    func saveNote(targetType: NoteTargetType, targetId: String, text: String) {
        let key = noteKey(targetType: targetType, targetId: targetId)
        notesByTarget[key] = NoteEntry(
            targetType: targetType,
            targetId: targetId,
            text: text,
            updatedAt: Date()
        )
        persistNotes()
    }

    private func noteKey(targetType: NoteTargetType, targetId: String) -> String {
        "\(targetType.rawValue):\(targetId)"
    }

    private func persistNotes() {
        guard let data = try? JSONEncoder().encode(notesByTarget) else { return }
        UserDefaults.standard.set(data, forKey: notesStorageKey)
    }

    private func loadPersistedNotes() {
        guard let data = UserDefaults.standard.data(forKey: notesStorageKey) else { return }
        guard let decoded = try? JSONDecoder().decode([String: NoteEntry].self, from: data) else { return }
        notesByTarget = decoded
    }
}

@MainActor
@Observable
final class ContactListViewModel {
    var contacts: [Contact] = []
    var isLoading = false
    var error: String?

    var totalUngraded: Int {
        contacts.reduce(0) { $0 + $1.ungradedCount }
    }

    private let service = SupabaseService.shared
    private var interactionsChannel: RealtimeChannelV2?
    private var interactionsTask: Task<Void, Never>?
    private var interactionsUpdateTask: Task<Void, Never>?
    private var smsChannel: RealtimeChannelV2?
    private var smsTask: Task<Void, Never>?
    private var smsUpdateTask: Task<Void, Never>?
    private var reviewQueueChannel: RealtimeChannelV2?
    private var reviewQueueTask: Task<Void, Never>?
    private var reviewQueueUpdateTask: Task<Void, Never>?
    private var realtimeReloadTask: Task<Void, Never>?
    private var liveRefreshTask: Task<Void, Never>?

    func loadContacts() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let fetched = try await service.fetchContactsList()
            contacts = sortNewestFirst(fetched)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetGradingClock() async {
        do {
            try await service.resetGradingClock()
            await loadContacts()
        } catch {
            self.error = "Reset failed: \(error.localizedDescription)"
        }
    }

    func subscribeToNewInteractions() async {
        guard interactionsChannel == nil else { return }

        let channel = service.client.channel("new-interactions")
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "interactions"
        )
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "interactions"
        )

        let smsChannel = service.client.channel("new-sms")
        let smsInserts = smsChannel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "sms_messages"
        )
        let smsUpdates = smsChannel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "sms_messages"
        )
        let reviewQueueChannel = service.client.channel("new-review-queue")
        let reviewQueueInserts = reviewQueueChannel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "review_queue"
        )
        let reviewQueueUpdates = reviewQueueChannel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "review_queue"
        )

        do {
            try await channel.subscribeWithError()
            try await smsChannel.subscribeWithError()
        } catch {
            await service.client.removeChannel(channel)
            await service.client.removeChannel(smsChannel)
            if shouldIgnoreRealtimeError(error) {
                return
            }
            print("Interactions realtime unavailable: \(error.localizedDescription)")
            if let channel = interactionsChannel {
                interactionsChannel = nil
                await service.client.removeChannel(channel)
            }
            await service.client.removeChannel(smsChannel)
            return
        }

        interactionsChannel = channel
        self.smsChannel = smsChannel
        do {
            try await reviewQueueChannel.subscribeWithError()
            self.reviewQueueChannel = reviewQueueChannel
        } catch {
            if !shouldIgnoreRealtimeError(error) {
                print("Review queue realtime unavailable: \(error.localizedDescription)")
            }
            await service.client.removeChannel(reviewQueueChannel)
        }
        error = nil

        interactionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in inserts {
                self.scheduleRealtimeReload()
            }
        }

        interactionsUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in updates {
                self.scheduleRealtimeReload()
            }
        }

        smsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in smsInserts {
                self.scheduleRealtimeReload()
            }
        }

        smsUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in smsUpdates {
                self.scheduleRealtimeReload()
            }
        }

        if self.reviewQueueChannel != nil {
            reviewQueueTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await _ in reviewQueueInserts {
                    self.scheduleRealtimeReload()
                }
            }

            reviewQueueUpdateTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await _ in reviewQueueUpdates {
                    self.scheduleRealtimeReload()
                }
            }
        }
    }

    func unsubscribe() async {
        interactionsTask?.cancel()
        interactionsTask = nil

        interactionsUpdateTask?.cancel()
        interactionsUpdateTask = nil

        smsTask?.cancel()
        smsTask = nil

        smsUpdateTask?.cancel()
        smsUpdateTask = nil

        reviewQueueTask?.cancel()
        reviewQueueTask = nil

        reviewQueueUpdateTask?.cancel()
        reviewQueueUpdateTask = nil

        realtimeReloadTask?.cancel()
        realtimeReloadTask = nil

        if let channel = interactionsChannel {
            interactionsChannel = nil
            await service.client.removeChannel(channel)
        }

        if let channel = smsChannel {
            smsChannel = nil
            await service.client.removeChannel(channel)
        }

        if let channel = reviewQueueChannel {
            reviewQueueChannel = nil
            await service.client.removeChannel(channel)
        }
    }

    func startLiveRefresh() {
        guard liveRefreshTask == nil else { return }

        liveRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self.reloadContactsFromRealtime()
            }
        }
    }

    func stopLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    private func reloadContactsFromRealtime() async {
        do {
            let fetched = try await service.fetchContactsList()
            contacts = sortNewestFirst(fetched)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scheduleRealtimeReload() {
        realtimeReloadTask?.cancel()
        realtimeReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !self.isLoading else { return }
            await self.reloadContactsFromRealtime()
        }
    }

    private func sortNewestFirst(_ rows: [Contact]) -> [Contact] {
        rows.sorted { lhs, rhs in
            let lhsDate = parseISO8601(lhs.lastActivity)
            let rhsDate = parseISO8601(rhs.lastActivity)

            switch (lhsDate, rhsDate) {
            case let (left?, right?):
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: raw) {
            return date
        }

        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        return basicFormatter.date(from: raw)
    }

    private func shouldIgnoreRealtimeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("cancellationerror") || message.contains("cancelled")
    }
}

private struct RealtimeGradeRecord: Decodable {
    let claimId: UUID
    let grade: String?
    let correctionText: String?
    let gradedBy: String?

    enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case grade
        case correctionText = "correction_text"
        case gradedBy = "graded_by"
    }
}

private struct RealtimeInteractionRecord: Decodable {
    let contactId: UUID?

    enum CodingKeys: String, CodingKey {
        case contactId = "contact_id"
    }
}

private struct RealtimeSMSRecord: Decodable {
    let contactPhone: String?
    let contactName: String?

    enum CodingKeys: String, CodingKey {
        case contactPhone = "contact_phone"
        case contactName = "contact_name"
    }
}

private struct RealtimeReviewQueueRecord: Decodable {
    let interactionId: String?
    let spanId: UUID?

    enum CodingKeys: String, CodingKey {
        case interactionId = "interaction_id"
        case spanId = "span_id"
    }
}

extension Notification.Name {
    static let redlineAttributionDidResolve = Notification.Name("redlineAttributionDidResolve")
}
