//
//  FollowButton.swift
//  Marauders
//

import SwiftUI

/// The Follow button of a profile and of a row in a follow list: red "Follow" until the viewer follows the account,
/// then grey "Following". The caller says what a tap does and sets the accessibility identifier, because each
/// screen's UI tests look its button up by its own.
struct FollowButton: View {
    let following: Bool
    /// The least width the button takes, so "Follow" and "Following" are the same size.
    let minWidth: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            (following ? Text("Following") : Text("Follow"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(following ? Color.primary : Color.white)
                .frame(minWidth: minWidth)
        }
        .buttonStyle(.borderedProminent)
        .tint(following ? Color(.systemGray5) : Color.likeRed)
        .animation(.snappy, value: following)
    }
}

#Preview {
    VStack(spacing: 16) {
        FollowButton(following: false, minWidth: 140) {}
        FollowButton(following: true, minWidth: 140) {}
        FollowButton(following: false, minWidth: 84) {}
    }
    .padding()
}
