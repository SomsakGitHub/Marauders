//
//  CopyableStatusBanner.swift
//  Marauders
//

import SwiftUI
import UIKit

struct CopyableStatusBanner: View {
    let message: String
    let isSuccess: Bool

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(isSuccess ? .green : .primary)
                .textSelection(.enabled)

            HStack {
                Button {
                    UIPasteboard.general.string = message
                    didCopy = true
                    AppLog.info("ui", "copied status banner to clipboard")
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Spacer()

                NavigationLink {
                    DebugLogView()
                } label: {
                    Label("View Log", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
            }
        }
        .alert("Copied", isPresented: $didCopy) {
            Button("OK", role: .cancel) {}
        }
    }
}
