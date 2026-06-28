import SwiftUI
import CrumbKit

/// An in-app demo of the OS-level Siri handoff. Mirrors what `CurateKitIntent` does when
/// invoked by "Hey Siri, ask Crumb…": resolve the phrase to a seed mission and land on
/// the Plan screen.
struct SiriHandoffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let examples = [
        "Pack me for a rainy weekend hike",
        "Set up my pour-over corner",
        "Make my desk feel calm",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
            HStack(spacing: CrumbMetrics.Space.s) {
                Image(systemName: "sparkles")
                    .foregroundStyle(CrumbColor.ochre)
                Text("Ask Crumb with Siri")
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
            }
            .padding(.top, CrumbMetrics.Space.l)

            Text("Saying any of these routes straight into the Plan screen with the "
                + "mission preselected. Try one here:")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(examples, id: \.self) { phrase in
                Button {
                    model.startMission(matching: phrase)
                    dismiss()
                } label: {
                    HStack(spacing: CrumbMetrics.Space.m) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(CrumbColor.pine)
                        Text("\u{201C}\(phrase)\u{201D}")
                            .font(CrumbType.body)
                            .foregroundStyle(CrumbColor.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(CrumbColor.ink3)
                    }
                    .padding(CrumbMetrics.Space.m)
                    .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                            .strokeBorder(CrumbColor.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.bottom, CrumbMetrics.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CrumbColor.paper)
    }
}
