import SwiftUI

/// The `home_banner` ad slot from the remote config. Labelled 推广 so it never
/// passes for a match; opens its link in the browser when it has one.
struct ConfigBanner: View {
    let slot: AppConfig.Slot

    var body: some View {
        if let link = slot.link {
            Link(destination: link) { content(showsArrow: true) }
                .tint(.primary)
        } else {
            content(showsArrow: false)
        }
    }

    private func content(showsArrow: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("推广")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(Palette.secondaryText)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.hairline))
                    Text(slot.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if !slot.detail.isEmpty {
                    Text(slot.detail).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if showsArrow {
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.tertiaryText)
            }
        }
        .contentShape(Rectangle())
    }
}
