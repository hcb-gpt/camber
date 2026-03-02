import SwiftUI

struct AIView: View {
    @Binding var isTriagePresented: Bool

    var body: some View {
        NavigationStack {
            AssistantChatView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isTriagePresented = true
                        } label: {
                            Label("Triage", systemImage: "checkmark.circle")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Open triage")
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

