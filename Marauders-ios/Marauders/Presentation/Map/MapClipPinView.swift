//
//  MapClipPinView.swift
//  Marauders
//

import SwiftUI

struct MapClipPinView: View {
    var body: some View {
        Image(systemName: "play.circle.fill")
            .font(.title)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .red)
            .shadow(radius: 2)
    }
}
