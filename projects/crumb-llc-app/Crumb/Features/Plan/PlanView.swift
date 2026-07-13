import SwiftUI
import CrumbKit

/// A frozen plan attached to one assistant turn. It deliberately has no fields or buttons: changes
/// are requested from ``MissionResponseDock`` and produce a new plan turn instead of rewriting
/// scrollback in place.
struct MissionPlanSnapshotView: View {
    let snapshot: MissionPlanSnapshot
    var isSuperseded = false

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Label("Shopping plan", systemImage: "list.bullet.clipboard")
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.pine)
                Spacer(minLength: CrumbMetrics.Space.s)
                if isSuperseded {
                    Text("Updated")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                }
            }

            Text(snapshot.title)
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                ForEach(Array(snapshot.parts.enumerated()), id: \.element.id) { index, part in
                    HStack(alignment: .firstTextBaseline, spacing: CrumbMetrics.Space.s) {
                        Text("\(index + 1)")
                            .font(CrumbType.captionStrong)
                            .foregroundStyle(CrumbColor.pine)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(part.label)
                            .font(CrumbType.body)
                            .foregroundStyle(CrumbColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .opacity(isSuperseded ? 0.72 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSuperseded ? "Updated shopping plan" : "Shopping plan")
        .accessibilityIdentifier("missionArtifact.plan.\(snapshot.id)")
    }
}
