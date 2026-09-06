import SwiftUI

struct ScoreFreshnessLine: View {
    @EnvironmentObject private var model: MatchListModel
    var now = Date()

    var body: some View {
        Text(model.scoreUpdateText(now: now))
            .font(.caption)
            .foregroundStyle(model.scoreNotice == nil ? Palette.secondaryText : Palette.accent)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MatchStatisticsView: View {
    let match: LiveMatch

    var body: some View {
        HStack(spacing: 24) {
            if let score = match.providerState?.halftimeText {
                statistic("半场", value: score)
            }
            if let corners = match.providerState?.cornersText {
                statistic("角球", value: corners)
            }
            if let summary = match.providerState?.basketballSummary {
                statistic("分差", value: String(summary.difference))
                statistic("总分", value: String(summary.total))
            }
        }
    }

    private func statistic(_ label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
            Text(value).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Palette.primaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ContinueWatchingLabel: View {
    let match: LiveMatch

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.circle.fill").font(.title).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("继续观看").font(.headline).foregroundStyle(Palette.primaryText)
                Text("\(match.homeTeam) vs \(match.awayTeam)")
                    .font(.subheadline).foregroundStyle(Palette.secondaryText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
