//
//  FriendPinView.swift
//  Marauders
//

import SwiftUI

/// A mutual follower on the map: their avatar in a green ring, with their handle and how long ago they were there.
struct FriendPinView: View {
    let friend: FriendLocation
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                AvatarView(url: friend.avatarURL, handle: friend.handle, size: 40)
                    .padding(3)
                    .background(Circle().fill(Color.green))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                VStack(spacing: 0) {
                    Text(friend.handle)
                        .font(.caption.weight(.semibold))
                    if let updatedAt = friend.updatedAt {
                        Text(updatedAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("map.friend")
    }

    private var accessibilityText: Text {
        guard let updatedAt = friend.updatedAt else { return Text(friend.handle) }
        return Text(friend.handle) + Text(verbatim: ", ") + Text(updatedAt, format: .relative(presentation: .named))
    }
}
