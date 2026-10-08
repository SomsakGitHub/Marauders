//
//  SplashView.swift
//  Marauders
//

import SwiftUI

struct SplashView: View {
    @State private var markScale: CGFloat = 0.88
    @State private var markOpacity = 0.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 58, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.15), radius: 12)

                Text("Marauders")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white)
            }
            .scaleEffect(markScale)
            .opacity(markOpacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                markScale = 1
                markOpacity = 1
            }
        }
    }
}

#Preview {
    SplashView()
}
