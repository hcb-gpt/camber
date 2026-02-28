import SwiftUI

struct CorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSubmit: (String) -> Void

    @State private var correctionText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Enter correction...", text: $correctionText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .lineLimit(3 ... 6)

                Button {
                    onSubmit(correctionText)
                    dismiss()
                } label: {
                    Text("Submit Correction")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding()
            .background(Color.black)
            .navigationTitle("Correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(200)])
        .preferredColorScheme(.dark)
    }
}
