import Foundation
import Observation

// MARK: - TriageAction (for undo)

enum TriageAction {
    case assigned(item: ReviewItem, projectId: String)
    case dismissed(item: ReviewItem)
    case skipped(item: ReviewItem, fromIndex: Int)
}

// MARK: - TriageViewModel

@MainActor
@Observable
final class TriageViewModel {

    // MARK: - Queue State

    var items: [ReviewItem] = []
    var projects: [ReviewProject] = []
    var currentIndex: Int = 0
    var totalPending: Int = 0
    var isLoading: Bool = false
    var error: String?
    var isSubmitting: Bool = false

    // MARK: - Session Stats

    var resolvedCount: Int = 0
    var dismissedCount: Int = 0
    var skippedCount: Int = 0
    var streak: Int = 0
    var sessionStart: Date = Date()

    // MARK: - Undo

    var lastAction: TriageAction?

    // MARK: - Computed

    var currentItem: ReviewItem? {
        guard currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    var hasMore: Bool {
        currentIndex < items.count
    }

    var progressFraction: Double {
        guard totalPending > 0 else { return 0 }
        let resolved = resolvedCount + dismissedCount
        return Double(resolved) / Double(totalPending)
    }

    var ratePerMinute: Double {
        let elapsed = Date().timeIntervalSince(sessionStart)
        guard elapsed > 10 else { return 0 }
        let total = Double(resolvedCount + dismissedCount)
        return (total / elapsed) * 60.0
    }

    // MARK: - Dependencies

    private let service = BootstrapService.shared

    // MARK: - Load Queue

    func loadQueue() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let response = try await service.fetchQueue()
            items = response.items
            projects = response.projects
            totalPending = response.totalPending
            currentIndex = 0
            sessionStart = Date()
            resolvedCount = 0
            dismissedCount = 0
            skippedCount = 0
            streak = 0
            lastAction = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Assign Project

    func assignProject(projectId: String) async {
        guard !isSubmitting else { return }
        guard let item = currentItem else { return }
        let itemId = item.id

        isSubmitting = true
        defer { isSubmitting = false }
        error = nil

        do {
            let result = try await service.resolve(queueId: itemId, projectId: projectId)

            if let chosenProjectId = result.chosenProjectId,
               chosenProjectId.lowercased() != projectId.lowercased()
            {
                self.error = "Selection mismatch detected. Queue reloaded."
                await loadQueue()
                return
            }

            if result.wasAlreadyResolved == true {
                advance(resolvedItemId: itemId)
                return
            }

            lastAction = .assigned(item: item, projectId: projectId)
            resolvedCount += 1
            streak += 1
            advance(resolvedItemId: itemId)
        } catch {
            self.error = error.localizedDescription
            lastAction = nil
        }
    }

    // MARK: - Skip (local reorder, no API call)

    func skip() {
        guard !isSubmitting else { return }
        guard let item = currentItem else { return }
        lastAction = .skipped(item: item, fromIndex: currentIndex)

        // Move current item to end of queue so it comes back around.
        items.remove(at: currentIndex)
        items.append(item)

        skippedCount += 1
        streak = 0
        // currentIndex stays the same — the next item slides into this slot.
    }

    // MARK: - Dismiss (mark as no-project / needs no attribution)

    func dismiss() async {
        guard !isSubmitting else { return }
        guard let item = currentItem else { return }
        let itemId = item.id

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await service.dismiss(queueId: itemId)
            lastAction = .dismissed(item: item)
            dismissedCount += 1
            streak = 0
            advance(resolvedItemId: itemId)
        } catch {
            self.error = error.localizedDescription
            lastAction = nil
        }
    }

    // MARK: - Undo

    func undo() async {
        guard !isSubmitting else { return }
        guard let action = lastAction else { return }
        lastAction = nil

        switch action {
        case .assigned(let item, _):
            // Re-insert the item at the front of the current position.
            resolvedCount = max(0, resolvedCount - 1)
            streak = max(0, streak - 1)
            reinsertAtFront(item)

            // Best-effort API revert.
            try? await service.undo(queueId: item.id)

        case .dismissed(let item):
            dismissedCount = max(0, dismissedCount - 1)
            reinsertAtFront(item)

            // Best-effort API revert.
            try? await service.undo(queueId: item.id)

        case .skipped(let item, let fromIndex):
            // Remove from tail (where skip placed it), restore to fromIndex.
            if let tailIndex = items.lastIndex(where: { $0.id == item.id }) {
                items.remove(at: tailIndex)
            }
            let insertAt = min(fromIndex, items.count)
            items.insert(item, at: insertAt)
            skippedCount = max(0, skippedCount - 1)
            currentIndex = insertAt
        }
    }

    // MARK: - Private Helpers

    private func advance(resolvedItemId: String) {
        guard let itemIndex = items.firstIndex(where: { $0.id == resolvedItemId }) else {
            return
        }

        items.remove(at: itemIndex)

        if currentIndex > itemIndex {
            currentIndex -= 1
        }
        if currentIndex >= items.count {
            currentIndex = max(items.count - 1, 0)
        }
    }

    private func reinsertAtFront(_ item: ReviewItem) {
        items.insert(item, at: currentIndex)
    }
}
