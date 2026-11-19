#if DEBUG
import SwiftUI

struct LibraryGridCardPreview: View {
    let width: CGFloat
    let scheme: ColorScheme

    private enum Kind: String, CaseIterable {
        case screenshot = "Screenshot", recording = "Recording", clip = "Clipboard text"

        var title: String {
            switch self {
            case .screenshot: "Project notes"
            case .recording: "Coastline recording"
            case .clip: "Meeting notes"
            }
        }

        var marks: LibraryCardMarks {
            switch self {
            case .screenshot:
                var marks = LibraryCardMarks(cloud: .shared, upload: nil, tall: false, content: .duration("0:19"))
                marks.settings = [.password, .expiry(.now.addingTimeInterval(3 * 86_400))]
                marks.social = [.comments(2), .likes(5)]
                return marks
            case .recording:
                return LibraryCardMarks(cloud: .unshared, upload: nil, tall: false, content: .duration("1:24"))
            case .clip:
                return LibraryCardMarks(cloud: nil, upload: nil, tall: false, content: .kind(.text))
            }
        }

        var icon: NSImage? {
            let symbol = switch self {
            case .screenshot: "macwindow"
            case .recording: "video.fill"
            case .clip: "note.text"
            }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        @ViewBuilder var picture: some View {
            switch self {
            case .screenshot:
                ZStack {
                    LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 3) {
                            ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 5, height: 5) }
                        }
                        Divider()
                        Text("Project notes").font(.headline)
                        Text("Review the first cut.").font(.caption)
                    }
                    .padding(9).background(.background, in: RoundedRectangle(cornerRadius: 6)).padding(12)
                }
            case .recording:
                ZStack {
                    LinearGradient(colors: [.cyan, .blue, .indigo], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "mountain.2.fill").resizable().scaledToFit().foregroundStyle(.white.opacity(0.35)).padding(12)
                    Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white)
                }
            case .clip:
                Text("Review the first cut on Friday.\nSend the final notes to the editor.")
                    .font(.system(size: 12)).lineLimit(6).padding(DS.Space.l).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private enum State: String, CaseIterable {
        case rest = "Rest", hover = "Hover", selected = "Selected", pressed = "Pressed"
    }

    var body: some View {
        let height = LibraryGridMetrics(width: width + 2 * LibraryGridMetrics.edgeMargin, cardWidth: width).cardHeight
        Grid(horizontalSpacing: 26, verticalSpacing: 26) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).font(.headline) }
            }
            ForEach(State.allCases, id: \.self) { state in
                GridRow {
                    Text(state.rawValue).font(.caption).gridColumnAlignment(.trailing)
                    ForEach(Kind.allCases, id: \.self) { kind in
                        LibraryGridCard(marks: kind.marks, cloudAction: {}, usesTextWell: kind == .clip) {
                            kind.picture
                        } caption: {
                            LibraryGridCaption(date: Date(timeIntervalSinceReferenceDate: 816_000_000),
                                               sourceIcon: kind.icon.map { ($0, false) }, saveAction: {}) {
                                Text(kind.title)
                            }
                        }
                        .modifier(LibraryCardSurface(layout: .grid, selected: state == .selected, hovering: state == .hover))
                        .environment(\.libraryCellPressed, state == .pressed)
                        .frame(width: width, height: height)
                    }
                }
            }
        }
        .padding(28)
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
        .environment(\.colorScheme, scheme)
    }
}

#Preview("Card 140 dark", traits: .sizeThatFitsLayout) { LibraryGridCardPreview(width: 140, scheme: .dark) }
#Preview("Card 140 light", traits: .sizeThatFitsLayout) { LibraryGridCardPreview(width: 140, scheme: .light) }
#Preview("Card 220 dark", traits: .sizeThatFitsLayout) { LibraryGridCardPreview(width: 220, scheme: .dark) }
#Preview("Card 220 light", traits: .sizeThatFitsLayout) { LibraryGridCardPreview(width: 220, scheme: .light) }
#Preview("Card 320 dark", traits: .sizeThatFitsLayout) { LibraryGridCardPreview(width: 320, scheme: .dark) }
#Preview("Card 320 light", traits: .sizeThatFitsLayout) { LibraryGridCardPreview(width: 320, scheme: .light) }
#endif
