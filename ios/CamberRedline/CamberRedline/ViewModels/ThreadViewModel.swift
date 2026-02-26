import Foundation
import Observation
import Supabase

enum NoteTargetType: String {
    case sms
    case span
    case call
}

struct NoteEntry: Identifiable, Hashable {
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

    // MARK: - Dependencies

    private let service = SupabaseService.shared
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
    private var threadRealtimeReloadTask: Task<Void, Never>?
    private let threadPageSize = 50
    private var currentThreadOffset = 0
    private var totalThreadCount = 0

    // MARK: - Load Thread

    func loadThread(contactId: UUID) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        currentThreadOffset = 0
        totalThreadCount = 0
        hasOlderThreadItems = false
        await loadThreadPage(contactId: contactId, offset: 0, resetItems: true)
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

        for raw in response.thread {
            guard let item = raw.toThreadItem() else { continue }
            switch item {
            case .call(let entry):
                if entry.interactionId.hasPrefix("cll_SHADOW_") {
                    continue
                }
                let allClaims = entry.allClaims
                let header = CallHeaderEntry(
                    interactionId: entry.interactionId,
                    eventAt: entry.eventAt,
                    contactName: entry.contactName,
                    direction: entry.direction,
                    channel: entry.channel,
                    summary: entry.summary,
                    claims: allClaims,
                    spans: entry.spans
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
                    spans: header.spans
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

        do {
            try await interactionsChannel.subscribeWithError()
            try await smsChannel.subscribeWithError()
        } catch {
            if shouldIgnoreRealtimeError(error) { return }
            print("Thread interactions realtime unavailable: \(error.localizedDescription)")
            await stopInteractionsSubscription()
            return
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

        threadRealtimeReloadTask?.cancel()
        threadRealtimeReloadTask = nil

        if let channel = threadInteractionsChannel {
            threadInteractionsChannel = nil
            await service.client.removeChannel(channel)
        }

        if let channel = threadSMSChannel {
            threadSMSChannel = nil
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
            await self.loadThread(contactId: contactId)
        }
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
    }

    private func noteKey(targetType: NoteTargetType, targetId: String) -> String {
        "\(targetType.rawValue):\(targetId)"
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
    private var realtimeReloadTask: Task<Void, Never>?
    private var liveRefreshTask: Task<Void, Never>?

    func loadContacts() async {
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

        do {
            try await channel.subscribeWithError()
            try await smsChannel.subscribeWithError()
        } catch {
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
    }

    func startLiveRefresh() {
        guard liveRefreshTask == nil else { return }

        liveRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(8))
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
