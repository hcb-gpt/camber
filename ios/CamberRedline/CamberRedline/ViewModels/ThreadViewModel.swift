import Foundation
import Observation
import Supabase

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

    func loadThread(contactId: UUID) {
        isLoading = true
        error = nil

        Task { @MainActor in
            await loadThreadInternal(contactId: contactId)
            isLoading = false
        }
    }

    private func loadThreadInternal(contactId: UUID) async {
        do {
            let response = try await service.fetchThread(contactId: contactId)
            let items = response.thread.compactMap { $0.toThreadItem() }
            threadItems = items.sorted { lhs, rhs in
                guard let ld = lhs.eventAtDate, let rd = rhs.eventAtDate else {
                    return false
                }
                return ld < rd
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Grade Claim

    func gradeClaim(
        claimId: UUID,
        grade: GradeType,
        correctionText: String? = nil
    ) {
        guard let contact = currentContact else { return }
        error = nil

        Task { @MainActor in
            do {
                try await service.gradeClaimViaAPI(
                    claimId: claimId,
                    grade: grade.rawValue,
                    correctionText: correctionText,
                    gradedBy: "ios_reviewer"
                )
                // Reload the thread to reflect the updated grade
                await loadThreadInternal(contactId: contact.contactId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Realtime (claim_grades)

    func startClaimGradeSubscription(contactId: UUID) {
        if subscribedContactId == contactId, gradeChannel != nil {
            return
        }

        stopClaimGradeSubscription()

        let channel = service.client.channel("claim-grades-\(contactId.uuidString.lowercased())")
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

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await channel.subscribeWithError()
            } catch {
                self.error = "Realtime unavailable: \(error.localizedDescription)"
                return
            }

            self.subscribedContactId = contactId
            self.gradeChannel = channel

            self.gradeInsertTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await insert in inserts {
                    self.mergeGrade(from: insert)
                }
            }

            self.gradeUpdateTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await update in updates {
                    self.mergeGrade(from: update)
                }
            }
        }
    }

    func stopClaimGradeSubscription() {
        gradeInsertTask?.cancel()
        gradeInsertTask = nil

        gradeUpdateTask?.cancel()
        gradeUpdateTask = nil

        subscribedContactId = nil

        if let channel = gradeChannel {
            gradeChannel = nil
            Task {
                await service.client.removeChannel(channel)
            }
        }
    }

    deinit {
        stopClaimGradeSubscription()
    }

    private func mergeGrade(from action: InsertAction) {
        guard
            let record = try? action.decodeRecord(
                as: RealtimeGradeRecord.self,
                decoder: PostgrestClient.Configuration.jsonDecoder
            )
        else { return }

        applyGradeUpdate(record)
    }

    private func mergeGrade(from action: UpdateAction) {
        guard
            let record = try? action.decodeRecord(
                as: RealtimeGradeRecord.self,
                decoder: PostgrestClient.Configuration.jsonDecoder
            )
        else { return }

        applyGradeUpdate(record)
    }

    private func applyGradeUpdate(_ record: RealtimeGradeRecord) {
        threadItems = threadItems.map { item in
            guard case .call(let entry) = item else { return item }

            let updatedSpans = entry.spans.map { span in
                let updatedClaims = span.claims.map { claim in
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

                return SpanEntry(
                    spanId: span.spanId,
                    spanIndex: span.spanIndex,
                    transcriptSegment: span.transcriptSegment,
                    claims: updatedClaims
                )
            }

            return .call(
                CallEntry(
                    interactionId: entry.interactionId,
                    eventAt: entry.eventAt,
                    direction: entry.direction,
                    summary: entry.summary,
                    spans: updatedSpans
                )
            )
        }
    }
}

@Observable
final class ContactListViewModel {
    var contacts: [Contact] = []
    var isLoading = false
    var error: String?

    private let service = SupabaseService.shared
    private var interactionsChannel: RealtimeChannelV2?
    private var interactionsTask: Task<Void, Never>?

    func loadContacts() {
        Task { @MainActor in
            isLoading = true
            error = nil

            do {
                contacts = try await service.fetchContactsList()
            } catch {
                self.error = error.localizedDescription
            }

            isLoading = false
        }
    }

    func subscribeToNewInteractions() {
        guard interactionsChannel == nil else { return }

        let channel = service.client.channel("new-interactions")
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "interactions"
        )

        interactionsTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await channel.subscribeWithError()
            } catch {
                self.error = "Realtime unavailable: \(error.localizedDescription)"
                return
            }

            self.interactionsChannel = channel

            for await _ in inserts {
                await self.reloadContactsFromRealtime()
            }
        }
    }

    func unsubscribe() {
        interactionsTask?.cancel()
        interactionsTask = nil

        if let channel = interactionsChannel {
            interactionsChannel = nil
            Task {
                await service.client.removeChannel(channel)
            }
        }
    }

    deinit {
        unsubscribe()
    }

    @MainActor
    private func reloadContactsFromRealtime() async {
        do {
            contacts = try await service.fetchContactsList()
        } catch {
            self.error = error.localizedDescription
        }
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
