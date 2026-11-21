//
//  ClientKeyBlockedView.swift
//  Marauders
//

import SwiftUI

/// What the window shows when this build does not carry the pass (`ClientKey.appMayRun()` is false): the app starts
/// nothing and this is its only screen. It says the build cannot run and never shows, or hints at, the value or the
/// pass.
struct ClientKeyBlockedView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)

                Text("This build cannot run")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                Text("This build has no valid client key, so the app does not start.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .multilineTextAlignment(.center)
            .padding(32)
        }
    }
}

#Preview {
    ClientKeyBlockedView()
}
