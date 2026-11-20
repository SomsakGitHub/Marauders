//
//  DebugLogView.swift
//  Marauders
//

import SwiftUI
import UIKit

// The in-app log is a Staging feature (the DEBUG flag). A Production build does not contain this type, and the guard
// Scripts/check-release-config.sh fails a build that does. Its texts are `Text(verbatim:)`, not catalog keys: a
// Production build does not have this screen, and a catalog sync from it would drop their keys (see
// LocalizationCatalogTests). "Copied" and "OK" stay localized, other screens use them too.
#if DEBUG
    struct DebugLogView: View {
        @Bindable private var store = AppLogStore.shared
        @State private var copyConfirmed = false

        /// Which Worker this build talks to and whether that came from its build or from an override, so that a
        /// screenshot or a pasted log says which environment it belongs to. `APIBaseURL.resolved()` logs nothing, so
        /// asking for it in `body` does not append to the log this screen is showing.
        private var apiHostCaption: String {
            guard let base = try? APIBaseURL.resolved() else { return "API URL unresolved" }
            return base.summary
        }

        var body: some View {
            List {
                if store.entries.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(verbatim: "No logs yet")
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    } description: {
                        Text(verbatim: "Upload or open the feed — events appear here")
                    }
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
            .navigationTitle(Text(verbatim: "Log"))
            .navigationSubtitle(Text(verbatim: apiHostCaption))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        store.clear()
                    } label: {
                        Text(verbatim: "Clear")
                    }
                    Button {
                        UIPasteboard.general.string = store.exportText
                        copyConfirmed = true
                    } label: {
                        Text(verbatim: "Copy All")
                    }
                }
            }
            .alert("Copied", isPresented: $copyConfirmed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: "Paste into chat or Notes")
            }
        }
    }

    #Preview {
        NavigationStack {
            DebugLogView()
        }
    }
#endif
