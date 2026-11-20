import ImageIO
import SwiftUI

extension EnvironmentValues {
    @Entry var libraryCellPressed = false
    @Entry var libraryCardDensity = LibraryCardDensity(width: 220)
}

struct LibraryGridCard<Picture: View, Caption: View>: View {
    let marks: LibraryCardMarks
    let cloudAction: () -> Void
    var cloudEnabled = true
    var usesTextWell = false
    @ViewBuilder let picture: () -> Picture
    @ViewBuilder let caption: () -> Caption
    @CurrentTheme private var theme

    var body: some View {
        GeometryReader { geometry in
            let density = LibraryCardDensity(width: geometry.size.width, inset: theme.card.inset, radius: theme.card.radius)
            let pictureHeight = max(1, geometry.size.height - density.pictureInset - LibraryGridMetrics.captionHeight)
            VStack(alignment: .leading, spacing: 0) {
                picture()
                    .frame(width: max(1, geometry.size.width - 2 * density.pictureInset),
                           height: pictureHeight)
                    .libraryCardChip(radius: density.pictureRadius, height: pictureHeight, usesTextWell: usesTextWell)
                    .overlay(alignment: .topLeading) { pills(settings(for: density), density: density) }
                    .overlay(alignment: .topTrailing) { cloudButton.padding(6) }
                    .overlay(alignment: .bottomLeading) { if density.showsSocial { pills(marks.social, density: density) } }
                    .overlay(alignment: .bottomTrailing) { pills(marks.content, density: density) }
                caption()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.card.gutter ?? density.pictureInset)
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
                    .foregroundStyle(theme.marks.idle.color).frame(width: 24, height: 24).cardMark(Circle())
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
                .cardPill(date <= .now ? .red : nil).help(CloudUploadText.expiryDate(date))
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
            Image(systemName: kind.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CardMark.kindSymbol)
                .padding([.bottom, .trailing], 2)
                .accessibilityLabel(kind.rawValue).help(kind.rawValue.capitalized)
        case .gallery(let n): Label("\(n)", systemImage: "photo.stack").cardPill().help("\(n) images")
        }
    }
    @ViewBuilder private func compactLabel(_ text: String, symbol: String, density: LibraryCardDensity) -> some View {
        if density.showsPillText { Label(text, systemImage: symbol) }
        else { Image(systemName: symbol).accessibilityLabel(text) }
    }

}

/// Grid cards share one surface, drawn by the theme's card recipe. List rows retain their compact backing.
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
    @CurrentTheme private var theme

    private var dark: Bool { scheme == .dark }
    private let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

    func body(content: Content) -> some View {
        if layout == .grid {
            let depth = LibraryCardDepth(hovering: hovering, pressed: pressed, deleting: deleting)
            let edge = theme.card.recipe.flatEdge
            GeometryReader { geometry in
                let radius = LibraryCardDensity(width: geometry.size.width, inset: theme.card.inset, radius: theme.card.radius).cornerRadius
                let outline = RoundedRectangle(cornerRadius: radius, style: .circular)
                content
                    .background {
                        switch theme.card.recipe {
                        case .stock(let stock): self.stock(stock, depth, shape: outline, radius: radius).allowsHitTesting(false)
                        case .flat: flat(depth, shape: outline, radius: radius).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        // Paper only: the caption strip under the picture, so a capture is never textured.
                        if theme.card.paper > 0 && contrast != .increased {
                            CardPaperGrain().opacity(theme.card.paper).frame(height: LibraryGridMetrics.captionHeight)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        // The picture's bottom edge: a line on its last half point, inside the card's outer edge.
                        if let pictureEdge = theme.card.pictureEdge {
                            Rectangle().fill(pictureEdge.color).frame(height: 0.5).padding(.horizontal, 0.5)
                                .padding(.bottom, LibraryGridMetrics.captionHeight).allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        // A flat card stays put: a press shades it instead of sinking it.
                        if edge != nil && pressed { outline.fill(.black.opacity(dark ? 0.25 : 0.08)).allowsHitTesting(false) }
                    }
                    .overlay {
                        if !selected && contrast == .increased {
                            outline.strokeBorder(Color.primary.opacity(0.65), lineWidth: 1)
                        } else if !selected, let edge {
                            // Hover firms the hairline up rather than lifting the card.
                            outline.strokeBorder(edge.color, lineWidth: hovering ? 1 : 0.5).allowsHitTesting(false)
                        } else {
                            LibraryCardBorder(selected: selected, shape: outline)
                        }
                    }
                    .offset(y: edge == nil ? depth.lift : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: depth)
            }
        } else {
            content
                .background(Color.primary.opacity(selected ? 0.075 : hovering ? 0.035 : 0.012), in: shape)
                .background(WorkspaceChrome.background, in: shape)
                .overlay { LibraryCardBorder(selected: selected) }
        }
    }

    private func stock(_ stock: AppTheme.Stock, _ depth: LibraryCardDepth, shape: RoundedRectangle, radius: CGFloat) -> some View {
        ZStack {
            if let key = depth.key { shadow(key, depth: depth, radius: radius) }
            if let contact = depth.contact { shadow(contact, depth: depth, radius: radius) }
            if let offset = depth.lowerLip { shape.fill(lip(stock, lower: true)).offset(y: offset) }
            if depth != .pressed { shape.fill(lip(stock, lower: false)).offset(y: 1) }
            shape.fill(LinearGradient(colors: theme.card.face.map(\.color), startPoint: .top, endPoint: .bottom))
            Canvas { context, size in
                let path = shape.path(in: CGRect(origin: .zero, size: size))
                context.clip(to: path)
                context.clip(to: path.offsetBy(dx: 0, dy: 1), options: .inverse)
                context.fill(path, with: .color(stock.gloss.color))
            }
        }
        .accessibilityHidden(true)
    }

    /// The stock card's two shadows under a flat face: no lips, no gloss, square when the theme's radius is 0.
    private func flat(_ depth: LibraryCardDepth, shape: RoundedRectangle, radius: CGFloat) -> some View {
        ZStack {
            if let key = depth.key { shadow(key, depth: depth, radius: radius) }
            if let contact = depth.contact { shadow(contact, depth: depth, radius: radius) }
            shape.fill(LinearGradient(colors: theme.card.face.map(\.color), startPoint: .top, endPoint: .bottom))
        }
        .accessibilityHidden(true)
    }

    private func shadow(_ spec: LibraryCardDepth.Shadow, depth: LibraryCardDepth, radius: CGFloat) -> some View {
        let alpha = depth == .pressed ? theme.card.pressedShadow : theme.card.shadow
        return LibraryShadowShape(inset: spec.inset, radius: radius).fill(.black)
            .shadow(color: .black.opacity(alpha), radius: spec.blur * theme.card.shadowBlur / 2, y: spec.offset * theme.card.shadowOffset)
    }

    private func lip(_ stock: AppTheme.Stock, lower: Bool) -> Color {
        guard selected else { return (lower ? stock.lowerLip : stock.upperLip).color }
        guard active else { return .secondary }
        let accent = NSColor.controlAccentColor
        if accent.usingColorSpace(.sRGB) == NSColor.systemBlue.usingColorSpace(.sRGB) {
            return Color(stock: lower ? (dark ? 0x064A99 : 0x0055B3) : 0x0A6FE0)
        }
        return Color.accentColor.mix(with: .black, by: lower ? (dark ? 0.4 : 0.3) : 0.12)
    }
}

/// Chip's paper grain, one tile for light and dark (the owner's pick, 2026-11-19: kraft, paper only, subtle), made
/// from ambientCG's Paper006 (CC0) by scripts/make-paper-grain.py. Its black marks at low alpha darken light paper
/// and its white marks lift dark paper, as a multiply and a screen would, without a blend mode: one translucent
/// image per card, at the theme's strength.
struct CardPaperGrain: View {
    private static let tile: CGImage? = Bundle.main.url(forResource: "PaperGrain", withExtension: "png")
        .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }

    var body: some View {
        if let tile = Self.tile {
            // 2x: one texel is half a point, as in the mockups.
            Image(decorative: tile, scale: 2).resizable(resizingMode: .tile)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
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
        let fonts: (title: Font, date: Font) = (.system(size: 14, weight: .medium), .system(size: 11))
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
