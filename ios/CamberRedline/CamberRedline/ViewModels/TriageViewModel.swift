import Foundation
import Observation

struct TriageSpan: Identifiable, Hashable {
    let queueId: String
    let spanId: String
    let transcriptSegment: String
    let aiGuessProjectId: String?
    let confidence: Double
    let reasonCodes: [String]

    var id: String { queueId }
}

struct TriageCall: Identifiable, Hashable {
    let interactionId: String
    let contactName: String
    let eventDate: Date
    let eventAt: String?
    let humanSummary: String?
    let fullTranscript: String
    var spans: [TriageSpan]

    var id: String { interactionId }
}

@MainActor
@Observable
final class TriageViewModel {
    var calls: [TriageCall] = []
    var projects: [ReviewProject] = []
    var totalPending: Int = 0
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var error: String?
    private(set) var resolvingQueueIDs: Set<String> = []

    var hasMorePages: Bool {
        loadedSpanCount < totalPending
    }

    private let service = BootstrapService.shared
    private let pageSize = 30
    private var currentLimit = 30
    private var projectNameById: [String: String] = [:]
    private var loadedSpanCount = 0

    func loadInitialQueue() async {
        currentLimit = pageSize
        await fetchQueue(limit: currentLimit, isPaginating: false)
    }

    func refreshQueue() async {
        await fetchQueue(limit: currentLimit, isPaginating: false)
    }

    func loadMoreIfNeeded(currentCall: TriageCall) async {
        guard let lastCall = calls.last, lastCall.id == currentCall.id else { return }
        guard hasMorePages, !isLoading, !isLoadingMore else { return }

        currentLimit += pageSize
        await fetchQueue(limit: currentLimit, isPaginating: true)
    }

    func projectName(for projectId: String?) -> String? {
        guard let projectId else { return nil }
        return projectNameById[projectId]
    }

    func isResolving(queueId: String) -> Bool {
        resolvingQueueIDs.contains(queueId)
    }

    func confirmAI(for span: TriageSpan) async {
        guard let aiProjectId = span.aiGuessProjectId else {
            error = "No AI project to confirm for this span."
            return
        }
        await assignProject(for: span, projectId: aiProjectId)
    }

    func assignProject(for span: TriageSpan, projectId: String) async {
        guard !resolvingQueueIDs.contains(span.queueId) else { return }
        resolvingQueueIDs.insert(span.queueId)
        defer { resolvingQueueIDs.remove(span.queueId) }

        do {
            let result = try await service.resolve(
                queueId: span.queueId,
                projectId: projectId,
                userId: "ios_reviewer"
            )

            if let chosenProjectId = result.chosenProjectId,
               chosenProjectId.lowercased() != projectId.lowercased()
            {
                error = "Selection mismatch detected. Queue reloaded."
                await refreshQueue()
                return
            }

            removeResolvedSpan(queueId: span.queueId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetchQueue(limit: Int, isPaginating: Bool) async {
        if isPaginating {
            isLoadingMore = true
        } else {
            isLoading = true
        }
        defer {
            if isPaginating {
                isLoadingMore = false
            } else {
                isLoading = false
            }
        }

        if !isPaginating {
            error = nil
        }

        do {
            let response = try await service.fetchQueue(limit: limit)
            let sortedItems = response.items.sorted { lhs, rhs in
                let lhsDate = lhs.sortDate
                let rhsDate = rhs.sortDate
                if lhsDate == rhsDate {
                    return lhs.id > rhs.id
                }
                return lhsDate > rhsDate
            }

            calls = buildCalls(from: sortedItems)
            totalPending = response.totalPending
            loadedSpanCount = sortedItems.count
            projects = response.projects
            projectNameById = Dictionary(
                uniqueKeysWithValues: response.projects.map { ($0.id, $0.name) }
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func buildCalls(from items: [ReviewItem]) -> [TriageCall] {
        let grouped = Dictionary(grouping: items, by: \.interactionId)
        var nextCalls: [TriageCall] = []
        nextCalls.reserveCapacity(grouped.count)

        for (interactionId, group) in grouped {
            let sortedGroup = group.sorted { lhs, rhs in
                if lhs.sortDate == rhs.sortDate {
                    return lhs.id > rhs.id
                }
                return lhs.sortDate > rhs.sortDate
            }
            guard let representative = sortedGroup.first else { continue }

            let resolvedContactName = sortedGroup
                .compactMap(\.contactName)
                .first(where: { !$0.isEmpty }) ?? "Unknown Correspondent"
            let resolvedHumanSummary = sortedGroup
                .compactMap(\.humanSummary)
                .first(where: { !$0.isEmpty })
            let resolvedTranscript = sortedGroup
                .compactMap(\.fullTranscript)
                .first(where: { !$0.isEmpty }) ?? sortedGroup
                .map(\.transcriptSegment)
                .joined(separator: "\n\n")

            let spans = sortedGroup.map { item in
                TriageSpan(
                    queueId: item.id,
                    spanId: item.spanId,
                    transcriptSegment: item.transcriptSegment,
                    aiGuessProjectId: item.aiGuessProjectId,
                    confidence: item.confidence,
                    reasonCodes: item.reasonCodes ?? []
                )
            }

            nextCalls.append(
                TriageCall(
                    interactionId: interactionId,
                    contactName: resolvedContactName,
                    eventDate: representative.sortDate,
                    eventAt: representative.eventAt ?? representative.createdAt,
                    humanSummary: resolvedHumanSummary,
                    fullTranscript: resolvedTranscript,
                    spans: spans
                )
            )
        }

        return nextCalls.sorted { lhs, rhs in
            if lhs.eventDate == rhs.eventDate {
                return lhs.interactionId > rhs.interactionId
            }
            return lhs.eventDate > rhs.eventDate
        }
    }

    private func removeResolvedSpan(queueId: String) {
        var updatedCalls: [TriageCall] = []
        updatedCalls.reserveCapacity(calls.count)

        for var call in calls {
            call.spans.removeAll(where: { $0.queueId == queueId })
            if !call.spans.isEmpty {
                updatedCalls.append(call)
            }
        }

        calls = updatedCalls
        loadedSpanCount = max(0, loadedSpanCount - 1)
        totalPending = max(0, totalPending - 1)
    }
}
