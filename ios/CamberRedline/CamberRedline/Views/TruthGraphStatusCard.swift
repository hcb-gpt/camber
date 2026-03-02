import SwiftUI
import UIKit

struct TruthGraphStatusCard: View {
    let missingCount: Int
    let interactionId: String

    @State private var isLoading = false
    @State private var truthGraph: TruthGraphResponse?
    @State private var errorMessage: String?
    @State private var lastRepairMessage: String?
    @State private var pendingRepair: TruthGraphSuggestedRepair?
    @State private var isRepairing = false

    private let service = SupabaseService.shared

    private let accentColor = Color(red: 0.95, green: 0.62, blue: 0.23)
    private let bgColor = Color(red: 0.12, green: 0.10, blue: 0.08)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if isLoading && truthGraph == nil {
                ProgressView()
                    .tint(.white)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let truthGraph {
                truthGraphBody(truthGraph)
            } else {
                Text("No Truth Graph data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastRepairMessage {
                Text(lastRepairMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .task { await load() }
        .alert("Run repair?", isPresented: Binding(get: { pendingRepair != nil }, set: { if !$0 { pendingRepair = nil } }), presenting: pendingRepair) { repair in
            Button(isRepairing ? "Running…" : "Run") {
                Task { await runRepair(repair) }
            }
            .disabled(isRepairing)

            Button("Cancel", role: .cancel) {
                pendingRepair = nil
            }
        } message: { repair in
            Text(repair.label)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Truth Graph")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                Text("\(missingCount) attribution\(missingCount == 1 ? "" : "s") missing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Refresh Truth Graph")
        }
    }

    @ViewBuilder
    private func truthGraphBody(_ truthGraph: TruthGraphResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lane")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(truthGraph.lane)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
            }

            hydrationGrid(truthGraph.hydration)

            if !truthGraph.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Warnings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(truthGraph.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            suggestedRepairsSection(truthGraph.suggestedRepairs)

            HStack(spacing: 8) {
                Text(interactionId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Copy ID") {
                    UIPasteboard.general.string = interactionId
                    lastRepairMessage = "Copied interaction_id"
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func hydrationGrid(_ hydration: TruthGraphHydration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hydration")
                .font(.caption)
                .foregroundStyle(.secondary)

            hydrationRow("calls_raw", hydration.callsRaw)
            hydrationRow("interactions", hydration.interactions)
            hydrationRow("conversation_spans", hydration.conversationSpans)
            hydrationRow("evidence_events", hydration.evidenceEvents)
            hydrationRow("span_attributions", hydration.spanAttributions)
            hydrationRow("journal_claims", hydration.journalClaims)
            hydrationRow("review_queue", hydration.reviewQueue)
        }
    }

    private func hydrationRow(_ label: String, _ value: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(value ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func suggestedRepairsSection(_ repairs: [TruthGraphSuggestedRepair]) -> some View {
        let hasEdgeSecret = RedlineInternalSettings.edgeSecret != nil

        if repairs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested repairs")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(repairs) { repair in
                    Button {
                        pendingRepair = repair
                    } label: {
                        HStack {
                            Text(repair.label)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "wrench.adjustable")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(accentColor.opacity(0.9))
                    .disabled(!hasEdgeSecret || isRepairing)
                }

                if !hasEdgeSecret {
                    Text("Set X-Edge-Secret in Settings → Internal to run repairs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor
    private func load() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            truthGraph = try await service.fetchTruthGraph(interactionId: interactionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runRepair(_ repair: TruthGraphSuggestedRepair) async {
        guard !isRepairing else { return }
        isRepairing = true
        defer {
            isRepairing = false
            pendingRepair = nil
        }

        do {
            let response = try await service.triggerTruthGraphRepair(
                interactionId: interactionId,
                repairAction: repair.action,
                idempotencyKey: repair.idempotencyKey
            )
            let status = response.status ?? "started"
            lastRepairMessage = "Repair request accepted (\(status))."
            await load()
        } catch {
            lastRepairMessage = error.localizedDescription
        }
    }
}
