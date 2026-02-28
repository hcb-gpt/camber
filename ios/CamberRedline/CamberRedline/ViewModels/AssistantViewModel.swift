import Foundation
import SwiftUI
import os

private enum AssistantRequestLogging {
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")
    static let smokeDriveFlag = "--smoke-drive"

    static var isSmokeDriveEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(smokeDriveFlag)
    }
}

struct AssistantMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    var content: String
    let timestamp = Date()

    enum MessageRole {
        case user
        case assistant
    }
}

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [AssistantMessage] = []
    @Published var isLoading = false
    @Published var currentInput = ""

    func sendMessage(contactId: String? = nil, projectId: String? = nil) async {
        let input = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let userMsg = AssistantMessage(role: .user, content: input)
        messages.append(userMsg)
        currentInput = ""
        isLoading = true

        let assistantMsg = AssistantMessage(role: .assistant, content: "")
        messages.append(assistantMsg)
        let assistantIndex = messages.count - 1

        do {
            let session = try await BootstrapService.shared.streamAssistantChat(
                message: input,
                contactId: contactId,
                projectId: projectId
            )

            if AssistantRequestLogging.isSmokeDriveEnabled,
               let requestId = session.debug.requestId,
               !requestId.isEmpty {
                AssistantRequestLogging.logger.log(
                    "SMOKE_EVENT ASSISTANT_REQUEST_ID request_id=\(requestId, privacy: .public) prompt=\(input, privacy: .public)"
                )
            }

            for try await chunk in session.stream {
                messages[assistantIndex].content += chunk
            }
        } catch {
            messages[assistantIndex].content += "\n\nError: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func clearChat() {
        messages = []
    }
}
