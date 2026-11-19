import SwiftUI

extension EnvironmentValues {
    @Entry var libraryCellPressed = false
    @Entry var libraryCardDensity = LibraryCardDensity(width: 220)
}

struct LibraryGridCard<Picture: View, Caption: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let marks: LibraryCardMarks
    let cloudAction: () -> Void
    var cloudEnabled = true
    @ViewBuilder let picture: () -> Picture
    @ViewBuilder let caption: () -> Caption

    var body: some View {
        GeometryReader { geometry in
            let density = LibraryCardDensity(width: geometry.size.width)
            let pictureHeight = max(1, geometry.size.height - density.pictureInset - LibraryGridMetrics.captionHeight)
            VStack(alignment: .leading, spacing: 0) {
                picture()
                    .frame(width: max(1, geometry.size.width - 2 * density.pictureInset),
                           height: pictureHeight)
                    .libraryCardChip(radius: density.pictureRadius, height: pictureHeight)
                    .overlay(alignment: .topLeading) { pills(settings(for: density), density: density) }
                    .overlay(alignment: .topTrailing) { cloudButton.padding(6) }
                    .overlay(alignment: .bottomLeading) { if density.showsSocial { pills(marks.social, density: density) } }
                    .overlay(alignment: .bottomTrailing) { pills(marks.content, density: density) }
                caption()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, density.pictureInset)
                    .padding(.top, LibraryGridMetrics.captionTopPadding)
            }
            .environment(\.libraryCardDensity, density)
            .padding([.top, .horizontal], density.pictureInset)
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
        case .kind(let kind):
            let colors = CardMark.kindColors(in: colorScheme)
            Image(systemName: kind.symbol)
                .cardPill(colors.symbol, fill: colors.fill)
                .accessibilityLabel(kind.rawValue).help(kind.rawValue.capitalized)
        case .gallery(let n): Label("\(n)", systemImage: "photo.stack").cardPill().help("\(n) images")
        }
    }
    @ViewBuilder private func compactLabel(_ text: String, symbol: String, density: LibraryCardDensity) -> some View {
        if density.showsPillText { Label(text, systemImage: symbol) }
        else { Image(systemName: symbol).accessibilityLabel(text) }
    }

}

/// Grid cards share one stock surface. List rows retain their compact backing.
struct LibraryCardSurface: ViewModifier {
    let layout: CaptureLibraryLayout
    let selected: Bool
    let hovering: Bool
    var deleting = false

    @Environment(\.libraryCellPressed) private var pressed
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appearsActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dark: Bool { scheme == .dark }
    private let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

    func body(content: Content) -> some View {
        if layout == .grid {
            let depth = LibraryCardDepth(hovering: hovering, pressed: pressed, deleting: deleting)
            GeometryReader { geometry in
                let radius = LibraryCardDensity(width: geometry.size.width).cornerRadius
                let outline = RoundedRectangle(cornerRadius: radius, style: .circular)
                content
                    .background { stock(depth, shape: outline, radius: radius).allowsHitTesting(false) }
                    .overlay {
                        if !selected && contrast == .increased {
                            outline.strokeBorder(Color.primary.opacity(0.65), lineWidth: 1)
                        } else {
                            LibraryCardBorder(selected: selected, shape: outline)
                        }
                    }
                    .offset(y: depth.lift)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: depth)
            }
        } else {
            content
                .background(Color.primary.opacity(selected ? 0.075 : hovering ? 0.035 : 0.012), in: shape)
                .background(WorkspaceChrome.background, in: shape)
                .overlay { LibraryCardBorder(selected: selected) }
        }
    }

    private func stock(_ depth: LibraryCardDepth, shape: RoundedRectangle, radius: CGFloat) -> some View {
        ZStack {
            if let key = depth.key { shadow(key, depth: depth, radius: radius) }
            if let contact = depth.contact { shadow(contact, depth: depth, radius: radius) }
            if let offset = depth.lowerLip { shape.fill(lip(lower: true)).offset(y: offset) }
            if depth != .pressed { shape.fill(lip(lower: false)).offset(y: 1) }
            shape.fill(LinearGradient(colors: dark ? [Color(stock: 0x333335), Color(stock: 0x2B2B2D)]
                                                   : [.white, Color(stock: 0xF7F7F8)], startPoint: .top, endPoint: .bottom))
            Canvas { context, size in
                let path = shape.path(in: CGRect(origin: .zero, size: size))
                context.clip(to: path)
                context.clip(to: path.offsetBy(dx: 0, dy: 1), options: .inverse)
                context.fill(path, with: .color(.white.opacity(dark ? 0.16 : 1)))
            }
        }
        .accessibilityHidden(true)
    }

    private func shadow(_ spec: LibraryCardDepth.Shadow, depth: LibraryCardDepth, radius: CGFloat) -> some View {
        let alpha = depth == .pressed ? (dark ? 0.5 : 0.12) : (dark ? 0.65 : 0.18)
        return LibraryShadowShape(inset: spec.inset, radius: radius).fill(.black)
            .shadow(color: .black.opacity(alpha), radius: spec.blur / 2, y: spec.offset)
    }

    private func lip(lower: Bool) -> Color {
        guard selected else {
            if dark { return Color(stock: lower ? 0x0A0A0A : 0x141414) }
            return Color(stock: lower ? 0xBDBDC2 : 0xD6D6DA)
        }
        guard active else { return .secondary }
        let accent = NSColor.controlAccentColor
        if accent.usingColorSpace(.sRGB) == NSColor.systemBlue.usingColorSpace(.sRGB) {
            return Color(stock: lower ? (dark ? 0x064A99 : 0x0055B3) : 0x0A6FE0)
        }
        return Color.accentColor.mix(with: .black, by: lower ? (dark ? 0.4 : 0.3) : 0.12)
    }
}

private extension Color {
    init(stock rgb: Int) {
        self.init(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct LibraryGridCaption<Title: View>: View {
    @Environment(\.libraryCardDensity) private var density
    let date: Date
    var sourceIcon: (image: NSImage, ringed: Bool)?
    var saveAction: (() -> Void)?
    var saveDisabled = false
    @State private var hoveringStar = false
    var capture: CaptureLibraryItem?
    @ViewBuilder let title: () -> Title

    var body: some View {
        let fonts: (title: Font, date: Font) = (.system(size: 13, weight: .medium), .caption)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                title()
                    .font(fonts.title).lineLimit(1).truncationMode(.tail).libraryRaisedText()
                Spacer(minLength: 0)
                if capture?.hasDraft == true {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange).libraryRaisedIcon()
                }
                if let capture, capture.session != nil { AgentPromptCardMark(item: capture, size: 16).id(capture.id).fixedSize().libraryRaisedIcon() }
            }
            .frame(height: 16)
            HStack(spacing: 4) {
                if let sourceIcon {
                    Image(nsImage: sourceIcon.image).resizable().frame(width: 13, height: 13)
                        .libraryRaisedIcon(ringed: sourceIcon.ringed)
                }
                Text(density.showsFullDate ? CaptureLibraryItem.dateTitle(date) : date.formatted(date: .omitted, time: .shortened)).lineLimit(1).libraryRaisedText()
                Spacer(minLength: 0)
                if let saveAction {
                    Button(action: saveAction) {
                        Image(systemName: "star")
                            .font(.system(size: 11, weight: hoveringStar ? .semibold : .regular))
                            .foregroundStyle(hoveringStar ? Color.primary : Color.secondary)
                            .libraryRaisedIcon()
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saveDisabled)
                    .onHover { hoveringStar = $0 }
                    .help("Move to Saved")
                    .accessibilityLabel("Move to Saved")
                }
            }
            .font(fonts.date).foregroundStyle(.secondary)
        }
    }
}
