import SwiftUI

struct DialView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "circle.grid.3x3")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Dial")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Coming soon: quick dial + contact lookup.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .navigationTitle("Dial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

