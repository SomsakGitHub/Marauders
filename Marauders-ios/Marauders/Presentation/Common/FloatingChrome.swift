//
//  FloatingChrome.swift
//  Marauders
//

import SwiftUI

/// How a pill, a tag or a button that floats over the map looks. The blurred backing is defined once, in
/// `floatingBacking`, so moving these to Liquid Glass is a change in this file and nowhere else.
extension View {
    /// The blurred backing every floating pill, tag and button shares.
    func floatingBacking<S: Shape>(in shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
    }

    /// A control floating over the map, in the shape it is tapped in: the blurred backing, a hairline edge and a soft
    /// shadow. A control that shows a state, such as the sharing capsule, can tint and thicken its edge.
    func floatingChrome<S: InsettableShape, Edge: ShapeStyle>(
        in shape: S, edge: Edge, edgeWidth: CGFloat = 0.5
    ) -> some View {
        floatingBacking(in: shape)
            .overlay { shape.strokeBorder(edge, lineWidth: edgeWidth) }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    /// A control floating over the map with the plain hairline edge.
    func floatingChrome<S: InsettableShape>(in shape: S) -> some View {
        floatingChrome(in: shape, edge: HierarchicalShapeStyle.quaternary)
    }

    /// A short status message floating over the map, such as "Finding your location…": subheadline text on a blurred
    /// capsule, without an edge or a shadow.
    func floatingStatusPill() -> some View {
        font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .floatingBacking(in: Capsule())
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.green, .blue], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        VStack(spacing: 16) {
            Text("Finding your location…").floatingStatusPill()
            HStack(spacing: 12) {
                Text("Search clips")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .floatingChrome(in: Capsule())
                Image(systemName: "location.fill")
                    .frame(width: 44, height: 44)
                    .floatingChrome(in: Circle())
                Text("Sharing")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .floatingChrome(in: Capsule(), edge: Color.green, edgeWidth: 1.5)
            }
        }
    }
}
