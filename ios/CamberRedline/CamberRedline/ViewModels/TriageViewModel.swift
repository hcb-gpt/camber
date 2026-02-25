import Foundation
import Observation

@MainActor
@Observable
final class TriageViewModel {
    var items: [ReviewItem] = []
    var totalPending: Int = 0
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var error: String?

    var hasMorePages: Bool {
        items.count < totalPending
    }

    private let service = BootstrapService.shared
    private let pageSize = 30
    private var currentLimit = 30
    private var projectNameById: [String: String] = [:]

    func loadInitialQueue() async {
        currentLimit = pageSize
        await fetchQueue(limit: currentLimit, isPaginating: false)
    }

    func refreshQueue() async {
        await fetchQueue(limit: currentLimit, isPaginating: false)
    }

    func loadMoreIfNeeded(currentItem: ReviewItem) async {
        guard let lastItem = items.last, lastItem.id == currentItem.id else { return }
        guard hasMorePages, !isLoading, !isLoadingMore else { return }

        currentLimit += pageSize
        await fetchQueue(limit: currentLimit, isPaginating: true)
    }

    func projectName(for projectId: String?) -> String? {
        guard let projectId else { return nil }
        return projectNameById[projectId]
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
            items = response.items.sorted { lhs, rhs in
                let lhsDate = lhs.sortDate
                let rhsDate = rhs.sortDate
                if lhsDate == rhsDate {
                    return lhs.id > rhs.id
                }
                return lhsDate > rhsDate
            }
            totalPending = response.totalPending
            projectNameById = Dictionary(
                uniqueKeysWithValues: response.projects.map { ($0.id, $0.name) }
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
