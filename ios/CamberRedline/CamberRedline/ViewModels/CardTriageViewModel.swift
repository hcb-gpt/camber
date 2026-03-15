import Foundation
import Observation
import os

private enum CardTriageSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }
}

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
    let reasonCodes: [String]
    let evidenceAnchors: [Anchor]
    let keywords: [String]

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
        reasonCodes = item.reasonCodes ?? item.reasons ?? []
        evidenceAnchors = item.contextPayload?.anchors ?? []
        keywords = item.contextPayload?.keywords ?? []
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
    var activityLog: [ActivityEntry] = []
    var skippedCount: Int = 0
    var escalatedCount: Int = 0

    private let service = BootstrapService.shared
    private var projectNameById: [String: String] = [:]
    private var totalAtLoad: Int = 0
    private var undoDeadline: Date?
    let sessionStartTime = Date()
    var cardViewStartTime: Date?

    struct TriageAction {
        let queueId: String
        let kind: Kind
        let timestamp: Date
        let label: String

        enum Kind { case resolved, dismissed, escalated, skipped }
    }

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let action: String       // "resolved", "dismissed", "escalated", "skipped"
        let reasonCode: String?
        let timeSpentSec: Int
        let timestamp: Date
        let contactName: String
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

    var isAttributionWritesLocked: Bool {
        service.writeLockState != nil
    }

    var attributionWritesLockedBannerText: String? {
        service.writesLockedBannerText
    }

    /// Cards resolved per hour based on session elapsed time.
    var resolveRatePerHour: Double {
        let elapsed = Date().timeIntervalSince(sessionStartTime)
        guard elapsed > 0, resolvedCount > 0 else { return 0 }
        return Double(resolvedCount) / elapsed * 3600
    }

    /// Average seconds spent per card (resolved + escalated + dismissed).
    var avgSecondsPerCard: Int {
        guard !activityLog.isEmpty else { return 0 }
        let total = activityLog.reduce(0) { $0 + $1.timeSpentSec }
        return total / activityLog.count
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
            cardViewStartTime = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Actions

    func resolve(_ card: CardItem, to projectId: String, notes: String? = nil) async {
        if let banner = service.writesLockedBannerText {
            error = banner
            return
        }

        let timeSpent = recordTimeSpent()
        guard let idx = queue.firstIndex(where: { $0.id == card.id }) else { return }
        queue.remove(at: idx)
        resolvedCount += 1

        activityLog.append(ActivityEntry(
            action: "resolved",
            reasonCode: nil,
            timeSpentSec: timeSpent,
            timestamp: Date(),
            contactName: card.contactName
        ))

        lastAction = TriageAction(
            queueId: card.queueId,
            kind: .resolved,
            timestamp: Date(),
            label: projectName(for: projectId) ?? "project"
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            let response = try await service.resolve(queueId: card.queueId, projectId: projectId, notes: notes)
            if CardTriageSmokeAutomation.isEnabled {
                let requestId = response.requestId ?? "missing"
                CardTriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_ACTION kind=resolve queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public) request_id=\(requestId, privacy: .public)"
                )
            }
        } catch {
            if let banner = service.writesLockedBannerText {
                self.error = banner
            } else {
                self.error = error.localizedDescription
            }
            lastAction = nil
            undoDeadline = nil
            queue.insert(CardItem(from: card), at: min(idx, queue.count))
            resolvedCount = max(0, resolvedCount - 1)
            activityLog.removeLast()
        }

        if queue.count < 5 {
            await prefetchMore()
        }
    }

    func dismiss(_ card: CardItem, reason: String? = nil, notes: String? = nil) async {
        if let banner = service.writesLockedBannerText {
            error = banner
            return
        }

        let timeSpent = recordTimeSpent()
        guard let idx = queue.firstIndex(where: { $0.id == card.id }) else { return }
        queue.remove(at: idx)
        resolvedCount += 1

        activityLog.append(ActivityEntry(
            action: "dismissed",
            reasonCode: reason,
            timeSpentSec: timeSpent,
            timestamp: Date(),
            contactName: card.contactName
        ))

        lastAction = TriageAction(
            queueId: card.queueId,
            kind: .dismissed,
            timestamp: Date(),
            label: card.contactName
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            let response = try await service.dismiss(queueId: card.queueId, reason: reason, notes: notes)
            if CardTriageSmokeAutomation.isEnabled {
                let requestId = response.requestId ?? "missing"
                CardTriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_ACTION kind=dismiss queue=\(card.queueId, privacy: .public) interaction=\(card.interactionId, privacy: .public) request_id=\(requestId, privacy: .public)"
                )
            }
        } catch {
            if let banner = service.writesLockedBannerText {
                self.error = banner
            } else {
                self.error = error.localizedDescription
            }
            lastAction = nil
            undoDeadline = nil
            queue.insert(CardItem(from: card), at: min(idx, queue.count))
            resolvedCount = max(0, resolvedCount - 1)
            activityLog.removeLast()
        }

        if queue.count < 5 {
            await prefetchMore()
        }
    }

    func dismissUndecided(_ card: CardItem, notes: String? = nil) async {
        await dismiss(card, reason: "undecided", notes: notes)
    }

    func escalate(_ card: CardItem, reason: String) async {
        if let banner = service.writesLockedBannerText {
            error = banner
            return
        }

        let timeSpent = recordTimeSpent()
        guard let idx = queue.firstIndex(where: { $0.id == card.id }) else { return }
        queue.remove(at: idx)
        resolvedCount += 1
        escalatedCount += 1

        activityLog.append(ActivityEntry(
            action: "escalated",
            reasonCode: reason,
            timeSpentSec: timeSpent,
            timestamp: Date(),
            contactName: card.contactName
        ))

        lastAction = TriageAction(
            queueId: card.queueId,
            kind: .escalated,
            timestamp: Date(),
            label: "escalated"
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            try await service.dismiss(
                queueId: card.queueId,
                reason: "escalated",
                notes: reason
            )
        } catch {
            if let banner = service.writesLockedBannerText {
                self.error = banner
            } else {
                self.error = error.localizedDescription
            }
            lastAction = nil
            undoDeadline = nil
            queue.insert(CardItem(from: card), at: min(idx, queue.count))
            resolvedCount = max(0, resolvedCount - 1)
            escalatedCount = max(0, escalatedCount - 1)
            activityLog.removeLast()
        }

        if queue.count < 5 {
            await prefetchMore()
        }
    }

    func skip(_ card: CardItem) {
        let timeSpent = recordTimeSpent()
        guard let idx = queue.firstIndex(where: { $0.id == card.id }) else { return }
        let removed = queue.remove(at: idx)
        queue.append(removed)
        skippedCount += 1

        activityLog.append(ActivityEntry(
            action: "skipped",
            reasonCode: nil,
            timeSpentSec: timeSpent,
            timestamp: Date(),
            contactName: card.contactName
        ))

        lastAction = TriageAction(
            queueId: card.queueId,
            kind: .skipped,
            timestamp: Date(),
            label: "skipped"
        )
        // No undo for skip — card is still in queue
        undoDeadline = nil
    }

    func undo() async {
        guard let action = lastAction, canUndo else { return }
        lastAction = nil
        undoDeadline = nil

        do {
            let response = try await service.undo(queueId: action.queueId)
            if CardTriageSmokeAutomation.isEnabled {
                let requestId = response.requestId ?? "missing"
                CardTriageSmokeAutomation.logger.log(
                    "SMOKE_EVENT TRIAGE_ACTION kind=undo queue=\(action.queueId, privacy: .public) request_id=\(requestId, privacy: .public)"
                )
            }
            resolvedCount = max(0, resolvedCount - 1)
            if action.kind == .escalated {
                escalatedCount = max(0, escalatedCount - 1)
            }
            await loadQueue()
        } catch {
            if let banner = service.writesLockedBannerText {
                self.error = banner
            } else {
                self.error = "Undo failed: \(error.localizedDescription)"
            }
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

    private func recordTimeSpent() -> Int {
        let now = Date()
        let spent = cardViewStartTime.map { Int(now.timeIntervalSince($0)) } ?? 0
        cardViewStartTime = now
        return spent
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
    init(from source: CardItem) {
        self.id = source.queueId
        self.queueId = source.queueId
        self.spanId = source.spanId
        self.interactionId = source.interactionId
        self.contactName = source.contactName
        self.eventDate = source.eventDate
        self.transcriptSegment = source.transcriptSegment
        self.projectId = source.projectId
        self.confidence = source.confidence
        self.candidates = source.candidates
        self.reasonCodes = source.reasonCodes
        self.evidenceAnchors = source.evidenceAnchors
        self.keywords = source.keywords
    }
}
