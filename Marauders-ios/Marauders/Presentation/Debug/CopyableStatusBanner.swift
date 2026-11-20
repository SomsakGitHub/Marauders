//
//  CopyableStatusBanner.swift
//  Marauders
//

import SwiftUI
import UIKit

struct CopyableStatusBanner: View {
    let message: String
    let isSuccess: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var didCopy = false

    /// Dark enough on white (5.6:1) and still 3:1 on the dark list row, where the system green was 2.2:1 on white.
    private static let successColor = Color(red: 31 / 255, green: 119 / 255, blue: 53 / 255)
    /// 4.9:1 on white and 3.5:1 on the dark list row.
    private static let failureColor = Color(red: 204 / 255, green: 64 / 255, blue: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The symbol, not the colour, tells success from failure, so it reads without telling colours apart. The
            // message is the whole statement for VoiceOver, so the symbol is hidden from it.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(isSuccess ? Self.successColor : Self.failureColor)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            if dynamicTypeSize.isAccessibilitySize {
                // Side by side the two buttons are squeezed until their words break in the middle: stacked, each has the
                // whole width.
                VStack(alignment: .leading, spacing: 10) {
                    copyButton
                    viewLogLink
                }
                // Every line the labels need: a squeezed list row cut "Copy Message" short.
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    copyButton
                    Spacer()
                    viewLogLink
                }
            }
        }
        .alert("Copied", isPresented: $didCopy) {
            Button("OK", role: .cancel) {}
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = message
            didCopy = true
            AppLog.info("ui", "copied status banner to clipboard")
        } label: {
            Label("Copy Message", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
    }

    /// The way into the in-app log, which only a Staging build has: a Production build shows Copy Message alone.
    @ViewBuilder
    private var viewLogLink: some View {
        #if DEBUG
            NavigationLink {
                DebugLogView()
            } label: {
                Label {
                    Text(verbatim: "View Log")
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            .buttonStyle(.bordered)
        #endif
    }
}
