import SwiftUI
import CrumbKit

/// Home / task entry. A short curator greeting and the seed missions as tappable cards.
struct MissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingSiriDemo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                greeting

                ForEach(model.missions) { task in
                    Button {
                        model.select(task)
                    } label: {
                        MissionCard(task: task)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mission.\(task.id)")
                }

                siriHint
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
        .accessibilityIdentifier("MissionsScreen")
        .sheet(isPresented: $isShowingSiriDemo) {
            SiriHandoffView()
                .crumbCompactSheet()
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Text("What are we shopping for?")
                .font(CrumbType.display)
                .foregroundStyle(CrumbColor.ink)
            Text("Hand me a mission. I'll do the legwork and bring you a kit.")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, CrumbMetrics.Space.s)
    }

    private var siriHint: some View {
        Button {
            isShowingSiriDemo = true
        } label: {
            HStack(spacing: CrumbMetrics.Space.m) {
                Image(systemName: "sparkles")
                    .foregroundStyle(CrumbColor.ochre)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask with Siri")
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                    Text("\u{201C}Hey Siri, ask Crumb to pack me for a rainy weekend hike\u{201D}")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(CrumbColor.ink3)
            }
            .crumbCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows how the Siri shortcut routes into Crumb")
    }
}

/// A single mission as a card: accent rail, title, subtitle, and a short parts preview.
struct MissionCard: View {
    let task: ShoppingTask

    private var accent: Color { Color(hex: task.accentHex) }

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.l) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent)
                .frame(width: 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                Text(task.title)
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
                    .multilineTextAlignment(.leading)
                Text(task.subtitle)
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)

                HStack(spacing: CrumbMetrics.Space.xs) {
                    Image(systemName: "list.bullet")
                        .imageScale(.small)
                    Text("^[\(task.plan.count) part](inflect: true) · ^[\(task.candidateIDs.count) pick](inflect: true)")
                }
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
                .padding(.top, CrumbMetrics.Space.xs)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.headline)
                .foregroundStyle(CrumbColor.ink3)
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .crumbShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title). \(task.subtitle)")
        .accessibilityHint("Opens the plan")
    }
}
