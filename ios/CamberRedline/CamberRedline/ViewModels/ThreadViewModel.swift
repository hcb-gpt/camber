import Foundation
import Observation

@Observable
final class ThreadViewModel {

    // MARK: - Published State

    var contacts: [Contact] = []
    var currentContact: Contact?
    var threadItems: [ThreadItem] = []
    var isLoading = false
    var error: String?

    // MARK: - Dependencies

    private let service = SupabaseService.shared

    // MARK: - Load Contacts

    func loadContacts() {
        isLoading = true
        error = nil

        Task { @MainActor in
            do {
                let fetched = try await service.fetchContacts()
                contacts = fetched
                // Auto-select the first contact and load its thread
                if let first = fetched.first {
                    currentContact = first
                    await loadThreadInternal(contactId: first.contactId)
                }
                isLoading = false
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

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
}
