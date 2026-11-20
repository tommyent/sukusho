//
//  StatusSuccess.swift
//  Screendrop
//

import SwiftUI

/// A success message in the Library's status bar, green as ever. On Glass's frost only the mark stays green and the
/// words take the primary ink, set here: the bar's own secondary style would otherwise reach them, and green or
/// secondary words over a light frost read at 1.2:1 and 3.5:1.
struct StatusSuccess: View {
    let title: String
    let systemImage: String
    /// Glass is drawn (`DrawnGlass`), which the bar knows.
    let onGlass: Bool

    var body: some View {
        if onGlass {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.green)
            }
        } else {
            Label(title, systemImage: systemImage).foregroundStyle(.green)
        }
    }
}
