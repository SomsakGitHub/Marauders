//
//  DebugLogView.swift
//  Marauders
//

import SwiftUI
import UIKit

struct DebugLogView: View {
    @Bindable private var store = AppLogStore.shared
    @State private var copyConfirmed = false

    var body: some View {
        List {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No logs yet",
                    systemImage: "doc.text",
                    description: Text("Upload or open the feed — events appear here")
                )
            } else {
                ForEach(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.formatted)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .listRowSeparator(.visible)
                }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Clear") {
                    store.clear()
                }
                Button("Copy All") {
                    UIPasteboard.general.string = store.exportText
                    copyConfirmed = true
                }
            }
        }
        .alert("Copied", isPresented: $copyConfirmed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Paste into chat or Notes")
        }
    }
}

#Preview {
    NavigationStack {
        DebugLogView()
    }
}
