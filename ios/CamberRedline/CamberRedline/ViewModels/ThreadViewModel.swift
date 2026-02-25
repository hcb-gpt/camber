import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class ThreadViewModel {

    // MARK: - Published State

    var currentContact: Contact?
    var threadItems: [ThreadItem] = []
    var isLoading = false
    var error: String?

    // MARK: - Dependencies

    private let service = SupabaseService.shared
    private var gradeChannel: RealtimeChannelV2?
    private var gradeInsertTask: Task<Void, Never>?
    private var gradeUpdateTask: Task<Void, Never>?
    private var subscribedContactId: UUID?

    // MARK: - Load Thread

    func loadThread(contactId: UUID) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        await loadThreadInternal(contactId: contactId)
    }

    private func loadThreadInternal(contactId: UUID) async {
        do {
            let response = try await service.fetchThread(contactId: contactId)
            var items: [ThreadItem] = []

            for raw in response.thread {
                guard let item = raw.toThreadItem() else { continue }
                switch item {
                case .call(let entry):
                    // Create compact call header with all claims aggregated
                    let allClaims = entry.allClaims
                    let header = CallHeaderEntry(
                        interactionId: entry.interactionId,
                        eventAt: entry.eventAt,
                        contactName: entry.contactName,
                        direction: entry.direction,
                        channel: entry.channel,
                        summary: entry.summary,
                        claims: allClaims
                    )
                    items.append(.callHeader(header))

                    // Use full transcript from calls_raw; fall back to span assembly
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
                        let contactName = response.contact.name
                        let turns = TranscriptParser.parse(
                            transcript, contactName: contactName
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

            // Don't re-sort. API returns chronological order.
            // Flattening preserves: callHeader -> speakerTurns -> next item
            threadItems = items
        } catch {
            self.error = error.localizedDescription
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
            await loadThreadInternal(contactId: contactId)
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
            self.error = "Realtime unavailable: \(error.localizedDescription)"
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
                    claims: updatedClaims
                )
            )
        }
    }

    private func shouldIgnoreRealtimeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

@MainActor
@Observable
final class ContactListViewModel {
    var contacts: [Contact] = []
    var isLoading = false
    var error: String?

    private let service = SupabaseService.shared
    private var interactionsChannel: RealtimeChannelV2?
    private var interactionsTask: Task<Void, Never>?

    func loadContacts() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            contacts = try await service.fetchContactsList()
        } catch {
            self.error = error.localizedDescription
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

        do {
            try await channel.subscribeWithError()
        } catch {
            if shouldIgnoreRealtimeError(error) {
                return
            }
            self.error = "Realtime unavailable: \(error.localizedDescription)"
            return
        }

        interactionsChannel = channel
        error = nil

        interactionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in inserts {
                await self.reloadContactsFromRealtime()
            }
        }
    }

    func unsubscribe() async {
        interactionsTask?.cancel()
        interactionsTask = nil

        if let channel = interactionsChannel {
            interactionsChannel = nil
            await service.client.removeChannel(channel)
        }
    }

    private func reloadContactsFromRealtime() async {
        do {
            contacts = try await service.fetchContactsList()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func shouldIgnoreRealtimeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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
