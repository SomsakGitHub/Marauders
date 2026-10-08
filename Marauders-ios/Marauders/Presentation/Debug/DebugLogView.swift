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
                    "ยังไม่มีบันทึก",
                    systemImage: "doc.text",
                    description: Text("ลองอัปโหลดหรือเปิดฟีด — เหตุการณ์จะแสดงที่นี่")
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
        .navigationTitle("บันทึก")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("ล้าง") {
                    store.clear()
                }
                Button("คัดลอกทั้งหมด") {
                    UIPasteboard.general.string = store.exportText
                    copyConfirmed = true
                }
            }
        }
        .alert("คัดลอกแล้ว", isPresented: $copyConfirmed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("วางในแชทหรือ Notes ได้เลย")
        }
    }
}

#Preview {
    NavigationStack {
        DebugLogView()
    }
}
