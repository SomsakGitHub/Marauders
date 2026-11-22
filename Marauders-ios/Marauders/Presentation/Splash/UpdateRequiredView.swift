//
//  UpdateRequiredView.swift
//  Marauders
//

import SwiftUI

/// What the window shows in place of the app when this build is below the minimum build the gate asks for
/// (docs/adr/012-force-update.md): one screen with one way out, the update link. No dismiss and no "later". The
/// content scrolls, so the largest text size stays reachable; VoiceOver reads the title (a header), the text and the
/// button.
struct UpdateRequiredView: View {
    let updateURL: URL

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.app")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .accessibilityHidden(true)

                        Text("Update required")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)

                        Text("This version of Marauders is too old to keep working. Update to continue.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))

                        Button {
                            openURL(updateURL)
                        } label: {
                            Text("Update")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    }
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

#Preview {
    UpdateRequiredView(updateURL: URL(string: "https://apps.apple.com/app/id0")!)
}
