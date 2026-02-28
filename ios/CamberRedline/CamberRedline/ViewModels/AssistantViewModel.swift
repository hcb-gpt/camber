import Foundation
import SwiftUI

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
            let stream = try await BootstrapService.shared.streamAssistantChat(
                message: input,
                contactId: contactId,
                projectId: projectId
            )

            for try await chunk in stream {
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
