import SwiftUI
import os

private enum AssistantSmokeAutomation {
    static let launchFlag = "--smoke-drive"
    static let assistantNotification = Notification.Name("camber.smoke.runAssistant")
    static let logger = Logger(subsystem: "CamberRedline", category: "smoke")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }
}

struct AssistantChatView: View {
    @StateObject private var viewModel = AssistantViewModel()
    @State private var didRunSmokeAssistant = false
    @State private var showSmokeContextPacket = false
    var contactId: String? = nil
    var projectId: String? = nil
    var initialMessage: String? = nil

    private let assistantTint = Color(red: 0.369, green: 0.361, blue: 0.902) // #5E5CE6

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if viewModel.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(viewModel.messages) { msg in
                                chatBubble(msg)
                                    .id(msg.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.messages.last?.content) { _, _ in
                    proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                }
            }

            inputArea
        }
        .navigationTitle(contactId != nil ? "Contact Assistant" : (projectId != nil ? "Project Assistant" : "Assistant"))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: AssistantContextDebugView()) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.clearChat()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationDestination(isPresented: $showSmokeContextPacket) {
            AssistantContextDebugView()
        }
        .task {
            if let initial = initialMessage, viewModel.messages.isEmpty {
                viewModel.currentInput = initial
                await viewModel.sendMessage(contactId: contactId, projectId: projectId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AssistantSmokeAutomation.assistantNotification)) { _ in
            guard AssistantSmokeAutomation.isEnabled else { return }
            guard !didRunSmokeAssistant else { return }
            didRunSmokeAssistant = true
            Task { await runSmokePrompts() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 50)
            Image(systemName: "brain.head.profile")
                .font(.system(size: 60))
                .foregroundStyle(assistantTint)
            
            Text("How can I help you today?")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.white)
            
            VStack(spacing: 12) {
                if projectId != nil {
                    suggestionButton("Tell me about this project")
                    suggestionButton("Who's coming tomorrow?")
                    suggestionButton("What's stuck / what's the holdup?")
                    suggestionButton("Any open loops?")
                } else if contactId != nil {
                    suggestionButton("What's the latest with this person?")
                    suggestionButton("Did they call back?")
                } else {
                    suggestionButton("What is going on recently?")
                }
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .multilineTextAlignment(.center)
    }

    private func suggestionButton(_ text: String) -> some View {
        Button {
            viewModel.currentInput = text
            Task { await viewModel.sendMessage(contactId: contactId, projectId: projectId) }
        } label: {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
                .foregroundStyle(.white)
        }
    }

    private func chatBubble(_ msg: AssistantMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 50) }
            
            Text(msg.content)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(msg.role == .user ? assistantTint : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
            
            if msg.role == .assistant { Spacer(minLength: 50) }
        }
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.1))
            
            HStack(spacing: 12) {
                TextField("Ask anything...", text: $viewModel.currentInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .foregroundStyle(.white)
                    .lineLimit(1...5)
                
                Button {
                    Task { await viewModel.sendMessage(contactId: contactId, projectId: projectId) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(viewModel.currentInput.isEmpty ? Color.gray : assistantTint)
                }
                .disabled(viewModel.currentInput.isEmpty || viewModel.isLoading)
            }
            .padding()
            .background(Color(red: 0.05, green: 0.05, blue: 0.05))
        }
    }

    @MainActor
    private func runSmokePrompts() async {
        AssistantSmokeAutomation.logger.log("SMOKE_EVENT ASSISTANT_OPEN_CONTEXT_PACKET")
        showSmokeContextPacket = true
        AssistantSmokeAutomation.logger.log("SMOKE_EVENT ASSISTANT_CONTEXT_FETCH")
        _ = try? await BootstrapService.shared.fetchAssistantContext()
        try? await Task.sleep(for: .seconds(4))
        showSmokeContextPacket = false
        try? await Task.sleep(for: .milliseconds(800))

        let prompts = [
            "Winship hardscape",
            "What projects do you have",
            "What is going on recently?"
        ]

        for prompt in prompts {
            viewModel.currentInput = prompt
            AssistantSmokeAutomation.logger.log("SMOKE_EVENT ASSISTANT_PROMPT prompt=\(prompt, privacy: .private)")
            await viewModel.sendMessage(contactId: contactId, projectId: projectId)
            try? await Task.sleep(for: .seconds(1))
        }

        AssistantSmokeAutomation.logger.log("SMOKE_EVENT ASSISTANT_DONE messages=\(viewModel.messages.count, privacy: .public)")
    }
}
