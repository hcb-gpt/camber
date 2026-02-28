import Foundation
import Observation

/// A single triage card: one review_queue item enriched with display metadata.
struct CardItem: Identifiable {
    let id: String          // review_queue ID
    let queueId: String
    let spanId: String
    let interactionId: String
    let contactName: String
    let eventDate: Date?
    let transcriptSegment: String
    let projectId: String?  // ai_guess_project_id
    let confidence: Double
    let candidates: [Candidate]

    init(from item: ReviewItem) {
        id = item.id
        queueId = item.id
        spanId = item.spanId
        interactionId = item.interactionId
        contactName = item.contactName ?? "Unknown"
        eventDate = item.sortDate == .distantPast ? nil : item.sortDate
        transcriptSegment = item.transcriptSegment.isEmpty
            ? (item.humanSummary ?? "No transcript available")
            : item.transcriptSegment
        projectId = item.aiGuessProjectId
        confidence = item.confidence ?? 0
        candidates = item.contextPayload?.candidates ?? []
    }
}

@MainActor
@Observable
final class CardTriageViewModel {
    var queue: [CardItem] = []
    var isLoading = false
    var error: String?
    var lastAction: TriageAction?
    var resolvedCount: Int = 0

    private let service = BootstrapService.shared
    private var projectNameById: [String: String] = [:]
    private var totalAtLoad: Int = 0
    private var undoDeadline: Date?

    struct TriageAction {
        let queueId: String
        let kind: Kind
        let timestamp: Date
        let label: String

        enum Kind { case resolved, dismissed }
    }

    var canUndo: Bool {
        guard let deadline = undoDeadline else { return false }
        return Date() < deadline
    }

    var progressFraction: Double {
        let total = resolvedCount + queue.count
        guard total > 0 else { return 0 }
        return Double(resolvedCount) / Double(total)
    }

    // MARK: - Load

    func loadQueue() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let response = try await service.fetchQueue(limit: 50)
            projectNameById = Dictionary(
                uniqueKeysWithValues: response.projects.map { ($0.id, $0.name) }
            )
            totalAtLoad = response.totalPending

            let sorted = response.items.sorted { $0.sortDate > $1.sortDate }
            queue = sorted.map { CardItem(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Actions

    func resolve(_ card: CardItem, to projectId: String) async {
        guard let idx = queue.firstIndex(where: { $0.id == card.id }) else { return }
        queue.remove(at: idx)
        resolvedCount += 1

        lastAction = TriageAction(
            queueId: card.queueId,
            kind: .resolved,
            timestamp: Date(),
            label: projectName(for: projectId) ?? "project"
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            _ = try await service.resolve(queueId: card.queueId, projectId: projectId)
        } catch {
            self.error = error.localizedDescription
            // Re-insert card on failure
            queue.insert(CardItem(queueId: card.queueId, spanId: card.spanId,
                                  interactionId: card.interactionId,
                                  contactName: card.contactName,
                                  eventDate: card.eventDate,
                                  transcriptSegment: card.transcriptSegment,
                                  projectId: card.projectId,
                                  confidence: card.confidence,
                                  candidates: card.candidates),
                         at: min(idx, queue.count))
            resolvedCount = max(0, resolvedCount - 1)
        }

        // Prefetch more if running low
        if queue.count < 5 {
            await prefetchMore()
        }
    }

    func dismiss(_ card: CardItem) async {
        guard let idx = queue.firstIndex(where: { $0.id == card.id }) else { return }
        queue.remove(at: idx)
        resolvedCount += 1

        lastAction = TriageAction(
            queueId: card.queueId,
            kind: .dismissed,
            timestamp: Date(),
            label: card.contactName
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            try await service.dismiss(queueId: card.queueId)
        } catch {
            self.error = error.localizedDescription
            queue.insert(
                CardItem(
                    queueId: card.queueId,
                    spanId: card.spanId,
                    interactionId: card.interactionId,
                    contactName: card.contactName,
                    eventDate: card.eventDate,
                    transcriptSegment: card.transcriptSegment,
                    projectId: card.projectId,
                    confidence: card.confidence,
                    candidates: card.candidates
                ),
                at: min(idx, queue.count)
            )
            resolvedCount = max(0, resolvedCount - 1)
        }

        if queue.count < 5 {
            await prefetchMore()
        }
    }

    func undo() async {
        guard let action = lastAction, canUndo else { return }
        lastAction = nil
        undoDeadline = nil

        do {
            try await service.undo(queueId: action.queueId)
            resolvedCount = max(0, resolvedCount - 1)
            await loadQueue()
        } catch {
            self.error = "Undo failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    func projectName(for projectId: String?) -> String? {
        guard let projectId else { return nil }
        return projectNameById[projectId]
    }

    func projectOptions(for card: CardItem) -> [ReviewProject] {
        var options: [ReviewProject] = []
        var seen: Set<String> = []

        // AI guess first
        if let pid = card.projectId, let name = projectNameById[pid] {
            options.append(ReviewProject(id: pid, name: name))
            seen.insert(pid)
        }

        // Candidates
        for c in card.candidates where !seen.contains(c.projectId) {
            options.append(ReviewProject(id: c.projectId, name: c.name))
            seen.insert(c.projectId)
        }

        // All projects
        for (pid, name) in projectNameById.sorted(by: { $0.value < $1.value }) {
            guard !seen.contains(pid) else { continue }
            options.append(ReviewProject(id: pid, name: name))
            seen.insert(pid)
        }

        return Array(options.prefix(20))
    }

    private func prefetchMore() async {
        guard !isLoading else { return }
        do {
            let response = try await service.fetchQueue(limit: 50)
            let newIds = Set(queue.map(\.id))
            let fresh = response.items
                .filter { !newIds.contains($0.id) }
                .sorted { $0.sortDate > $1.sortDate }
                .map { CardItem(from: $0) }
            queue.append(contentsOf: fresh)

            // Update project names
            for p in response.projects {
                projectNameById[p.id] = p.name
            }
        } catch {
            // Silent — prefetch is best-effort
        }
    }

    private func startUndoTimer() {
        Task {
            try? await Task.sleep(for: .seconds(26))
            if lastAction != nil {
                lastAction = nil
                undoDeadline = nil
            }
        }
    }
}

// Convenience initializer for re-inserting on error
private extension CardItem {
    init(queueId: String, spanId: String, interactionId: String,
         contactName: String, eventDate: Date?, transcriptSegment: String,
         projectId: String?, confidence: Double, candidates: [Candidate]) {
        self.id = queueId
        self.queueId = queueId
        self.spanId = spanId
        self.interactionId = interactionId
        self.contactName = contactName
        self.eventDate = eventDate
        self.transcriptSegment = transcriptSegment
        self.projectId = projectId
        self.confidence = confidence
        self.candidates = candidates
    }
}
