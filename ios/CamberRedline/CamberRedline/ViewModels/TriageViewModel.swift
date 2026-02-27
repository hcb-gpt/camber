import Foundation
import Observation

struct TriageSpan: Identifiable {
    let id: String
    let queueId: String
    let spanId: String
    let interactionId: String
    let transcriptSegment: String
    var projectId: String?
    let confidence: Double
    let reasonCodes: [String]
    let candidates: [Candidate]
    let isMock: Bool
}

struct TriageCall: Identifiable {
    let id: String
    let interactionId: String
    let contactName: String
    let eventDate: Date
    let humanSummary: String?
    let fullTranscript: String
    var spans: [TriageSpan]
    let isMock: Bool

    var hasMultipleProjects: Bool {
        Set(spans.compactMap(\.projectId)).count > 1
    }
}

@MainActor
@Observable
final class TriageViewModel {
    var calls: [TriageCall] = []
    var totalPending: Int = 0
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var error: String?

    var loadedSpanCount: Int {
        calls.reduce(0) { partialResult, call in
            partialResult + call.spans.filter { !$0.isMock }.count
        }
    }

    var multiProjectCallCount: Int {
        calls.filter(\.hasMultipleProjects).count
    }

    var hasMorePages: Bool {
        loadedSpanCount < totalPending
    }

    private let service = BootstrapService.shared
    private let pageSize = 30
    private var currentLimit = 30
    private var projectNameById: [String: String] = [:]
    private var reviewProjects: [ReviewProject] = []

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

    func projectOptions(for span: TriageSpan) -> [ReviewProject] {
        var options: [ReviewProject] = []
        var seenProjectIds: Set<String> = []

        if let current = span.projectId {
            options.append(
                ReviewProject(
                    id: current,
                    name: projectNameById[current] ?? "Current Project"
                )
            )
            seenProjectIds.insert(current)
        }

        for candidate in span.candidates {
            if seenProjectIds.contains(candidate.projectId) { continue }
            options.append(
                ReviewProject(id: candidate.projectId, name: candidate.name)
            )
            seenProjectIds.insert(candidate.projectId)
        }

        for project in reviewProjects {
            if seenProjectIds.contains(project.id) { continue }
            options.append(project)
            seenProjectIds.insert(project.id)
        }

        return Array(options.prefix(18))
    }

    func resolveSpan(_ span: TriageSpan, to projectId: String) async {
        do {
            _ = try await service.resolve(queueId: span.queueId, projectId: projectId)
            await refreshQueue()
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

            reviewProjects = response.projects
            totalPending = response.totalPending
            projectNameById = Dictionary(
                uniqueKeysWithValues: response.projects.map { ($0.id, $0.name) }
            )
            calls = hydrateCalls(sortedItems)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func hydrateCalls(_ items: [ReviewItem]) -> [TriageCall] {
        let grouped = Dictionary(grouping: items, by: \.interactionId)
        var hydrated = grouped.map { interactionId, groupedItems -> TriageCall in
            let orderedItems = groupedItems.sorted { lhs, rhs in
                if lhs.sortDate == rhs.sortDate {
                    return lhs.id < rhs.id
                }
                return lhs.sortDate < rhs.sortDate
            }

            let head = orderedItems.last ?? groupedItems[0]
            let spans = orderedItems.map { item in
                TriageSpan(
                    id: item.id,
                    queueId: item.id,
                    spanId: item.spanId,
                    interactionId: item.interactionId,
                    transcriptSegment: item.transcriptSegment,
                    projectId: item.aiGuessProjectId,
                    confidence: item.confidence ?? 0,
                    reasonCodes: item.reasonCodes ?? item.reasons ?? [],
                    candidates: item.contextPayload?.candidates ?? [],
                    isMock: false
                )
            }

            let transcript = orderedItems
                .compactMap(\.fullTranscript)
                .first { !$0.isEmpty }
                ?? orderedItems.map(\.transcriptSegment).joined(separator: "\n\n")

            return TriageCall(
                id: interactionId,
                interactionId: interactionId,
                contactName: head.contactName ?? "Unknown Contact",
                eventDate: head.sortDate,
                humanSummary: head.humanSummary,
                fullTranscript: transcript,
                spans: spans,
                isMock: false
            )
        }

        hydrated.sort { lhs, rhs in
            if lhs.eventDate == rhs.eventDate {
                return lhs.interactionId > rhs.interactionId
            }
            return lhs.eventDate > rhs.eventDate
        }

        return hydrated
    }
}
