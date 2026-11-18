import SwiftUI

struct LibraryGridCard<Picture: View, Caption: View>: View {
    let marks: LibraryCardMarks
    let cloudAction: () -> Void
    var cloudEnabled = true
    @ViewBuilder let picture: () -> Picture
    @ViewBuilder let caption: () -> Caption

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                picture()
                    .frame(width: max(1, geometry.size.width - 2 * LibraryGridMetrics.pictureInset),
                           height: max(1, geometry.size.height - LibraryGridMetrics.pictureInset - LibraryGridMetrics.captionHeight))
                    .libraryCardChip()
                    .overlay(alignment: .topLeading) { pills(marks.settings) }
                    .overlay(alignment: .topTrailing) { cloudButton.padding(6) }
                    .overlay(alignment: .bottomLeading) { pills(marks.social) }
                    .overlay(alignment: .bottomTrailing) { pills(marks.content) }
                caption().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding([.top, .horizontal], LibraryGridMetrics.pictureInset)
        }
    }

    @ViewBuilder private var cloudButton: some View {
        switch marks.cloud {
        case .unshared, .shared:
            CardCloudBadge(isShared: marks.cloud == .shared, action: cloudAction).disabled(!cloudEnabled)
        case .received:
            Button(action: cloudAction) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CardMark.idle).frame(width: 24, height: 24).cardMark(Circle())
            }
            .buttonStyle(.plain).help("Download received file").accessibilityLabel("Download received file")
        case nil: EmptyView()
        }
    }

    private func pills(_ values: [LibraryCardMarks.Pill]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in pill(value) }
        }
        .fixedSize().padding(6)
    }

    @ViewBuilder private func pill(_ mark: LibraryCardMarks.Pill) -> some View {
        switch mark {
        case .encrypted: Image(systemName: "lock.shield.fill").cardPill().help("End-to-end encrypted")
        case .password: Image(systemName: "lock.fill").cardPill().help("Password protected")
        case .expiry(let date):
            Label(CloudUploadText.expiryShort(date), systemImage: "hourglass")
                .cardPill(date <= .now ? .red : CardMark.text).help(CloudUploadText.expiryDate(date))
        case .comments(let n):
            Label { Text(n.formatted()) } icon: { Image(systemName: "bubble.left.fill").foregroundStyle(.blue) }
                .cardPill().help(CloudUploadText.comments(n) ?? "")
        case .likes(let n):
            Label { Text(n.formatted()) } icon: { Image(systemName: "heart.fill").foregroundStyle(.red) }
                .cardPill().help(CloudUploadText.likes(n) ?? "")
        case .tall: TallCapture.badge
        case .versions(let n): Label("\(n)", systemImage: "square.stack").cardPill().help("\(n) versions")
        case .duration(let time): Label(time, systemImage: "play.fill").cardPill().monospacedDigit()
        case .kind(let word): Text(word).cardPill()
        case .gallery(let n): Label("\(n)", systemImage: "photo.stack").cardPill().help("\(n) images")
        }
    }
}
