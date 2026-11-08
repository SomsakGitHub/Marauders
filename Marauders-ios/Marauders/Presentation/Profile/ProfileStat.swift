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

/// A count that opens the list behind it (Following, Followers). A signed-in viewer pushes `route` in the profile's
/// stack; a guest still sees the number, and a tap on it asks them to sign in through `onSignInRequired`, because the
/// lists are for signed-in viewers.
///
/// The accessibility sits on the link itself, so VoiceOver finds one button that reads the label, the count as its
/// value and a hint, and the caller's `accessibilityIdentifier` lands on that same element.
struct ProfileCountLink: View {
    let count: Int
    let label: LocalizedStringKey
    let route: ProfileRoute
    let isSignedIn: Bool
    let onSignInRequired: () -> Void

    init(
        count: Int,
        label: LocalizedStringKey,
        route: ProfileRoute,
        isSignedIn: Bool = true,
        onSignInRequired: @escaping () -> Void = {}
    ) {
        self.count = count
        self.label = label
        self.route = route
        self.isSignedIn = isSignedIn
        self.onSignInRequired = onSignInRequired
    }

    var body: some View {
        Group {
            if isSignedIn {
                NavigationLink(value: route) {
                    ProfileStat(count: count, label: label)
                }
            } else {
                Button(action: onSignInRequired) {
                    ProfileStat(count: count, label: label)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(count.formatted())
        .accessibilityHint("Opens the list")
        .accessibilityAddTraits(.isButton)
    }
}
