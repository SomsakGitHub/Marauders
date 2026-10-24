import SwiftUI

/// Entry point only; Apple authorization is presented centrally by ContentView.
struct SignInRequiredView: View {
    let onSignIn: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Sign in required", systemImage: "person.crop.circle")
        } description: {
            Text("Sign in to continue. You will return here afterwards.")
        } actions: {
            Button("Sign in", action: onSignIn)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("auth.openSignIn")
        }
        .accessibilityElement(children: .contain)
    }
}
