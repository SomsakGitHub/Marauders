//
//  ProfileStat.swift
//  Marauders
//

import SwiftUI

/// One number in a profile's header with what it counts under it, as on TikTok. VoiceOver reads the label, then the
/// number as its value.
struct ProfileStat: View {
    let count: Int
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Text(count.formatted(.number.notation(.compactName)))
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(count.formatted())
    }
}
