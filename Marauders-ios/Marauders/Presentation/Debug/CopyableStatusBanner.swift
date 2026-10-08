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
                    Label("คัดลอกข้อความ", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Spacer()

                NavigationLink {
                    DebugLogView()
                } label: {
                    Label("ดู log", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
            }
        }
        .alert("คัดลอกแล้ว", isPresented: $didCopy) {
            Button("OK", role: .cancel) {}
        }
    }
}
