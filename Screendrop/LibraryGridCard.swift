import SwiftUI

extension EnvironmentValues {
    @Entry var libraryCardDensity = LibraryCardDensity(width: 220)
}

struct LibraryGridCard<Picture: View, Caption: View>: View {
    let marks: LibraryCardMarks
    let cloudAction: () -> Void
    var cloudEnabled = true
    @ViewBuilder let picture: () -> Picture
    @ViewBuilder let caption: () -> Caption

    var body: some View {
        GeometryReader { geometry in
            let density = LibraryCardDensity(width: geometry.size.width)
            VStack(alignment: .leading, spacing: 0) {
                picture()
                    .frame(width: max(1, geometry.size.width - 2 * LibraryGridMetrics.pictureInset),
                           height: max(1, geometry.size.height - LibraryGridMetrics.pictureInset - LibraryGridMetrics.captionHeight))
                    .libraryCardChip()
                    .overlay(alignment: .topLeading) { pills(settings(for: density), density: density) }
                    .overlay(alignment: .topTrailing) { cloudButton.padding(6) }
                    .overlay(alignment: .bottomLeading) { if density.showsSocial { pills(marks.social, density: density) } }
                    .overlay(alignment: .bottomTrailing) { pills(marks.content, density: density) }
                caption().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .environment(\.libraryCardDensity, density)
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

    private func settings(for density: LibraryCardDensity) -> [LibraryCardMarks.Pill] {
        if !density.separatesLocks && marks.settings.contains(.encrypted) && marks.settings.contains(.password) {
            return marks.settings.filter { $0 != .password }
        }
        return marks.settings
    }

    private func pills(_ values: [LibraryCardMarks.Pill], density: LibraryCardDensity) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in pill(value, density: density) }
        }
        .fixedSize().padding(6)
    }

    @ViewBuilder private func pill(_ mark: LibraryCardMarks.Pill, density: LibraryCardDensity) -> some View {
        switch mark {
        case .encrypted: Image(systemName: "lock.shield.fill").cardPill().help("End-to-end encrypted")
        case .password: Image(systemName: "lock.fill").cardPill().help("Password protected")
        case .expiry(let date):
            compactLabel(CloudUploadText.expiryShort(date), symbol: "hourglass", density: density)
                .cardPill(date <= .now ? .red : CardMark.text).help(CloudUploadText.expiryDate(date))
        case .comments(let n):
            Label { Text(n.formatted()) } icon: { Image(systemName: "bubble.left.fill").foregroundStyle(.blue) }
                .cardPill().help(CloudUploadText.comments(n) ?? "")
        case .likes(let n):
            Label { Text(n.formatted()) } icon: { Image(systemName: "heart.fill").foregroundStyle(.red) }
                .cardPill().help(CloudUploadText.likes(n) ?? "")
        case .tall: TallCapture.badge
        case .versions(let n): compactLabel("\(n)", symbol: "square.stack", density: density).cardPill().help("\(n) versions")
        case .duration(let time): Label(time, systemImage: "play.fill").cardPill().monospacedDigit()
        case .kind(let word):
            if density.showsPillText { Text(word).cardPill() }
            else {
                Image(systemName: word == "code" ? "chevron.left.forwardslash.chevron.right" : word == "link" ? "link" : "text.alignleft")
                    .cardPill().accessibilityLabel(word).help(word.capitalized)
            }
        case .gallery(let n): Label("\(n)", systemImage: "photo.stack").cardPill().help("\(n) images")
        }
    }
    @ViewBuilder private func compactLabel(_ text: String, symbol: String, density: LibraryCardDensity) -> some View {
        if density.showsPillText { Label(text, systemImage: symbol) }
        else { Image(systemName: symbol).accessibilityLabel(text) }
    }

}

struct LibraryGridCaption<Title: View>: View {
    @Environment(\.libraryCardDensity) private var density
    let date: Date
    var bundleID: String?
    var saved = false
    var capture: CaptureLibraryItem?
    @ViewBuilder let title: () -> Title

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                title()
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail).libraryRaisedText()
                Spacer(minLength: 0)
                if capture?.hasDraft == true { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange) }
                if let capture, capture.session != nil { AgentPromptCardMark(item: capture, size: 16).id(capture.id).fixedSize() }
            }
            .frame(height: 16)
            HStack(spacing: 4) {
                if let icon = ClipboardHistoryModel.shared.appIcon(bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                        .libraryRaisedIcon(ringed: ClipboardHistoryModel.shared.appIconIsLight(bundleID))
                }
                Text(density.showsFullDate ? CaptureLibraryItem.dateTitle(date) : date.formatted(date: .omitted, time: .shortened)).lineLimit(1).libraryRaisedText()
                Spacer(minLength: 0)
                if saved { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow).accessibilityLabel("Saved") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
