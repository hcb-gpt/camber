import SwiftUI

struct CallsView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "phone")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Calls")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Coming soon: Beside-parity calls list + filters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .navigationTitle("Calls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

