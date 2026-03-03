import Foundation
import Observation
import os

private enum CardTriageSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let truthSurfaceLocalFlag = "--smoke-truth-surface-local"
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }

    static var truthSurfaceLocalEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(truthSurfaceLocalFlag)
    }
}

private enum CardTriageLearningLoopMetrics {
    static let logger = Logger(subsystem: "CamberRedline", category: "learning_loop")

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}

enum TriageSurfaceMode: String, CaseIterable {
    case contractor
    case dev
}

/// A single triage card: one review_queue item enriched with display metadata.
struct CardItem: Identifiable {
    let id: String          // review_queue ID
    let queueId: String
    let spanId: String
    let interactionId: String
    let contactName: String
    let eventDate: Date?
    let humanSummary: String?
    let transcriptSegment: String
    let projectId: String?  // ai_guess_project_id
    let confidence: Double
    let candidates: [Candidate]
    let reasonCodes: [String]
    let evidenceAnchors: [Anchor]
    let keywords: [String]
    let modelId: String?
    let promptVersion: String?
    let contextCreatedAtUtc: String?

    init(
        id: String,
        queueId: String,
        spanId: String,
        interactionId: String,
        contactName: String,
        eventDate: Date?,
        humanSummary: String?,
        transcriptSegment: String,
        projectId: String?,
        confidence: Double,
        candidates: [Candidate],
        reasonCodes: [String],
        evidenceAnchors: [Anchor],
        keywords: [String],
        modelId: String?,
        promptVersion: String?,
        contextCreatedAtUtc: String?
    ) {
        self.id = id
        self.queueId = queueId
        self.spanId = spanId
        self.interactionId = interactionId
        self.contactName = contactName
        self.eventDate = eventDate
        self.humanSummary = humanSummary
        self.transcriptSegment = transcriptSegment
        self.projectId = projectId
        self.confidence = confidence
        self.candidates = candidates
        self.reasonCodes = reasonCodes
        self.evidenceAnchors = evidenceAnchors
        self.keywords = keywords
        self.modelId = modelId
        self.promptVersion = promptVersion
        self.contextCreatedAtUtc = contextCreatedAtUtc
    }

    init(from item: ReviewItem) {
        let trimmedHumanSummary = item.humanSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        id = item.id
        queueId = item.id
        spanId = item.spanId
        interactionId = item.interactionId
        contactName = item.contactName ?? "Unknown"
        eventDate = item.sortDate == .distantPast ? nil : item.sortDate
        humanSummary = (trimmedHumanSummary?.isEmpty == false) ? trimmedHumanSummary : nil
        transcriptSegment = item.transcriptSegment.isEmpty
            ? (humanSummary ?? "No transcript available")
            : item.transcriptSegment
        projectId = item.aiGuessProjectId
        confidence = item.confidence ?? 0
        candidates = item.contextPayload?.candidates ?? []
        reasonCodes = item.reasonCodes ?? item.reasons ?? []
        evidenceAnchors = item.contextPayload?.anchors ?? []
        keywords = item.contextPayload?.keywords ?? []
        modelId = item.contextPayload?.modelId
        promptVersion = item.contextPayload?.promptVersion
        contextCreatedAtUtc = item.contextPayload?.createdAtUtc
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
    private var recentProjectIds: [String] = []
    private let recentProjectsDefaultsKey = "triage_recent_project_ids_v1"
    let sessionStartTime = Date()
    var cardViewStartTime: Date?

    struct TriageAction {
        struct ActionReceipt {
            let queueId: String
            let requestId: String?

            var compactLabel: String {
                let queueShort = String(queueId.prefix(8))
                if let requestId, !requestId.isEmpty {
                    let requestShort = String(requestId.prefix(10))
                    return "q:\(queueShort) • r:\(requestShort)"
                }
                return "q:\(queueShort)"
            }

            var copyText: String {
                if let requestId, !requestId.isEmpty {
                    return "queue_id=\(queueId)\nrequest_id=\(requestId)"
                }
                return "queue_id=\(queueId)"
            }
        }

        let queueId: String
        let kind: Kind
        let timestamp: Date
        let title: String
        let receipt: ActionReceipt?

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

    func recoverWriteAccess() async -> BootstrapWriteRecoveryOutcome {
        let outcome = await service.recoverWriteAccess()
        switch outcome {
        case .unlocked:
            error = nil
        case .stillLocked(let state):
            error = BootstrapServiceError.writesLocked(state).errorDescription
        case .failed(let message, _, _):
            error = message
        }
        return outcome
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

    init() {
        loadRecentProjectIds()
    }

    // MARK: - Load

    func loadQueue() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            if CardTriageSmokeAutomation.isEnabled, CardTriageSmokeAutomation.truthSurfaceLocalEnabled {
                service.clearWriteLock()

                let projectId = "proj_smoke_truth_surface_v1"
                projectNameById = [projectId: "Smoke — Truth Surface (v1)"]
                totalAtLoad = 1

                queue = [
                    CardItem(
                        id: "rq_smoke_truth_surface_v1",
                        queueId: "rq_smoke_truth_surface_v1",
                        spanId: "spn_smoke_truth_surface_v1",
                        interactionId: "cll_smoke_truth_surface_v1",
                        contactName: "Smoke Test",
                        eventDate: Date().addingTimeInterval(-3600),
                        humanSummary: "Caller confirmed Winship hardscape scope and timeline.",
                        transcriptSegment: "I want the Winship hardscape like we discussed last week.",
                        projectId: projectId,
                        confidence: 0.83,
                        candidates: [
                            Candidate(name: "Smoke — Truth Surface (v1)", projectId: projectId, evidenceTags: ["keyword"])
                        ],
                        reasonCodes: ["unknown_project"],
                        evidenceAnchors: [
                            Anchor(
                                text: "Winship hardscape",
                                quote: "I want the Winship hardscape like we discussed last week.",
                                matchType: "keyword",
                                candidateProjectId: projectId
                            )
                        ],
                        keywords: ["winship", "hardscape"],
                        modelId: "smoke-model-v1",
                        promptVersion: "smoke-prompt-v1",
                        contextCreatedAtUtc: ISO8601DateFormatter().string(from: Date())
                    )
                ]
                cardViewStartTime = Date()
                CardTriageSmokeAutomation.logger.log("SMOKE_EVENT TRIAGE_LOCAL_QUEUE_READY items=1")
                return
            }

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
            CardTriageLearningLoopMetrics.log(
                "KPI_EVENT AUTH_LOCK_BLOCKED surface=triage_cards action=resolve queue=\(card.queueId)"
            )
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
            title: "Saved",
            receipt: .init(queueId: card.queueId, requestId: nil)
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            let response = try await service.resolve(queueId: card.queueId, projectId: projectId, notes: notes)
            rememberProjectSelection(projectId)
            lastAction = TriageAction(
                queueId: card.queueId,
                kind: .resolved,
                timestamp: Date(),
                title: "Saved",
                receipt: .init(queueId: card.queueId, requestId: response.requestId)
            )
            CardTriageLearningLoopMetrics.log(
                "KPI_EVENT WRITE_ACTION surface=triage_cards action=resolve queue=\(card.queueId) request_id=\(response.requestId ?? "missing")"
            )
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
            CardTriageLearningLoopMetrics.log(
                "KPI_EVENT AUTH_LOCK_BLOCKED surface=triage_cards action=dismiss queue=\(card.queueId)"
            )
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
            title: "Saved",
            receipt: .init(queueId: card.queueId, requestId: nil)
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            let response = try await service.dismiss(queueId: card.queueId, reason: reason, notes: notes)
            lastAction = TriageAction(
                queueId: card.queueId,
                kind: .dismissed,
                timestamp: Date(),
                title: "Saved",
                receipt: .init(queueId: card.queueId, requestId: response.requestId)
            )
            CardTriageLearningLoopMetrics.log(
                "KPI_EVENT WRITE_ACTION surface=triage_cards action=dismiss queue=\(card.queueId) request_id=\(response.requestId ?? "missing")"
            )
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
            CardTriageLearningLoopMetrics.log(
                "KPI_EVENT AUTH_LOCK_BLOCKED surface=triage_cards action=escalate queue=\(card.queueId)"
            )
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
            title: "Saved",
            receipt: .init(queueId: card.queueId, requestId: nil)
        )
        undoDeadline = Date().addingTimeInterval(25)
        startUndoTimer()

        do {
            let response = try await service.dismiss(
                queueId: card.queueId,
                reason: "escalated",
                notes: reason
            )
            CardTriageLearningLoopMetrics.log(
                "KPI_EVENT WRITE_ACTION surface=triage_cards action=escalate queue=\(card.queueId) request_id=\(response.requestId ?? "missing")"
            )
            lastAction = TriageAction(
                queueId: card.queueId,
                kind: .escalated,
                timestamp: Date(),
                title: "Saved",
                receipt: .init(queueId: card.queueId, requestId: response.requestId)
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
            title: "Skipped",
            receipt: nil
        )
        // No undo for skip — card is still in queue
        undoDeadline = nil
    }

    func undo() async {
        guard let action = lastAction, canUndo else { return }
        lastAction = nil
        undoDeadline = nil
        let undoneKind: String = switch action.kind {
        case .resolved: "resolved"
        case .dismissed: "dismissed"
        case .escalated: "escalated"
        case .skipped: "skipped"
        }

        do {
            let response = try await service.undo(queueId: action.queueId)
            CardTriageLearningLoopMetrics.log(
                "KPI_EVENT UNDO_COMMIT surface=triage_cards queue=\(action.queueId) undo_of=\(undoneKind) request_id=\(response.requestId ?? "missing")"
            )
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
                CardTriageLearningLoopMetrics.log(
                    "KPI_EVENT AUTH_LOCK_BLOCKED surface=triage_cards action=undo queue=\(action.queueId)"
                )
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

    func suggestedProject(for card: CardItem) -> ReviewProject? {
        guard let suggestedProjectId = card.projectId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suggestedProjectId.isEmpty else {
            return nil
        }

        if let projectName = projectNameById[suggestedProjectId] {
            return ReviewProject(id: suggestedProjectId, name: projectName)
        }

        if let candidate = card.candidates.first(where: { $0.projectId == suggestedProjectId }) {
            return ReviewProject(id: suggestedProjectId, name: candidate.name)
        }

        return ReviewProject(id: suggestedProjectId, name: "Suggested Project")
    }

    func recentProjects(for card: CardItem, limit: Int = 5) -> [ReviewProject] {
        var projectById: [String: ReviewProject] = [:]
        for option in projectOptions(for: card) {
            projectById[option.id] = option
        }
        for (projectId, projectName) in projectNameById {
            if projectById[projectId] == nil {
                projectById[projectId] = ReviewProject(id: projectId, name: projectName)
            }
        }

        let suggestedProjectId = card.projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        var recentProjects: [ReviewProject] = []
        for projectId in recentProjectIds {
            if let suggestedProjectId, suggestedProjectId == projectId {
                continue
            }
            guard let project = projectById[projectId] else { continue }
            recentProjects.append(project)
            if recentProjects.count >= limit {
                break
            }
        }

        return recentProjects
    }

    func rememberProjectSelection(_ projectId: String) {
        let trimmedProjectId = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProjectId.isEmpty else { return }

        recentProjectIds.removeAll(where: { $0 == trimmedProjectId })
        recentProjectIds.insert(trimmedProjectId, at: 0)
        if recentProjectIds.count > 8 {
            recentProjectIds = Array(recentProjectIds.prefix(8))
        }
        persistRecentProjectIds()
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

    private func persistRecentProjectIds() {
        UserDefaults.standard.set(recentProjectIds, forKey: recentProjectsDefaultsKey)
    }

    private func loadRecentProjectIds() {
        let stored = UserDefaults.standard.stringArray(forKey: recentProjectsDefaultsKey) ?? []
        recentProjectIds = stored.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        self.humanSummary = source.humanSummary
        self.transcriptSegment = source.transcriptSegment
        self.projectId = source.projectId
        self.confidence = source.confidence
        self.candidates = source.candidates
        self.reasonCodes = source.reasonCodes
        self.evidenceAnchors = source.evidenceAnchors
        self.keywords = source.keywords
        self.modelId = source.modelId
        self.promptVersion = source.promptVersion
        self.contextCreatedAtUtc = source.contextCreatedAtUtc
    }
}
