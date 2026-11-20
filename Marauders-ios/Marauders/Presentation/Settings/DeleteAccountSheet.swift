//
//  DeleteAccountSheet.swift
//  Marauders
//

import AuthenticationServices
import SwiftUI

/// The sheet that deletes the viewer's account: it says what goes, has Apple confirm that the viewer is the owner, shows
/// the progress and ends with the confirmation. One view per phase of `AccountDeletionViewModel`.
struct DeleteAccountSheet: View {
    let viewModel: AccountDeletionViewModel
    /// The viewer is a test user of the Simulator's debug sign in. It has no Apple ID to confirm with, so a Debug build
    /// offers it a plain button in place of Apple's.
    var isTestUser = false
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.phase != .deleted {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onClose)
                            .disabled(viewModel.phase == .deleting)
                            .accessibilityIdentifier("deleteAccount.cancel")
                    }
                }
            }
        }
        // A deletion that is under way is not interrupted by a swipe, and Cancel waits for it too.
        .interactiveDismissDisabled(viewModel.phase == .deleting)
        .accessibilityIdentifier("deleteAccount.sheet")
        .onChange(of: viewModel.phase) { _, phase in announce(phase) }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .deleting, .failed:
            confirmation
        case .deleted:
            confirmed
        }
    }

    // MARK: - One view for each phase

    /// What goes, and the way to confirm it. While the account is being deleted the text stays and the button gives way
    /// to the progress; after a failure the message sits above the button, which can be tapped again.
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This permanently deletes your Marauders account and everything in it:")
            VStack(alignment: .leading, spacing: 8) {
                bullet { Text("your clips") }
                bullet { Text("your comments, likes and follows") }
                bullet { Text("your profile and photo") }
                bullet { Text("your shared location") }
            }
            Text("This cannot be undone.")
                .fontWeight(.semibold)
            Text("To confirm, continue with Apple. Your account is deleted as soon as Apple confirms it's you.")
                .foregroundStyle(.secondary)
            if viewModel.phase == .deleting {
                progress
            } else {
                if case .failed(let message) = viewModel.phase {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("deleteAccount.error")
                }
                confirmButton
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Deleting your account…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deleteAccount.progress")
    }

    private var confirmed: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Your account was deleted")
                .font(.title3.weight(.semibold))
            Text("Everything in it was removed from Marauders.")
                .foregroundStyle(.secondary)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("deleteAccount.done")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private func bullet<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•")
                .accessibilityHidden(true)
            content()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The button that confirms

    @ViewBuilder
    private var confirmButton: some View {
        #if DEBUG
            // Developer-only texts are `verbatim`, not catalog keys: a Release build does not have these buttons, and a
            // catalog sync from it would drop their keys (see LocalizationCatalogTests).
            if AppRuntimeConfiguration.isUITesting {
                // Apple's sheet cannot be driven by a UI test, so a plain button stands in for Apple's.
                plainButton(identifier: "deleteAccount.appleButton") { Text(verbatim: "Confirm deletion (UI test)") }
            } else if isTestUser {
                plainButton(identifier: "deleteAccount.testUser") { Text(verbatim: "Delete test user") }
            } else {
                appleButton
            }
        #else
            appleButton
        #endif
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = []
        } onCompletion: { result in
            Task { await viewModel.handleAuthorization(result) }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
        .accessibilityIdentifier("deleteAccount.appleButton")
    }

    #if DEBUG
        /// A plain button that asks for no Apple confirmation, so it deletes with no code.
        private func plainButton<Label: View>(identifier: String, @ViewBuilder label: () -> Label) -> some View {
            Button {
                Task { await viewModel.delete(authorizationCode: nil) }
            } label: {
                label()
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier(identifier)
        }
    #endif

    // MARK: - VoiceOver

    /// What happened is said aloud, the way a failed comment is: the sheet changes under the person's finger.
    private func announce(_ phase: AccountDeletionViewModel.Phase) {
        switch phase {
        case .failed(let message):
            AccessibilityNotification.Announcement(message).post()
        case .deleted:
            AccessibilityNotification.Announcement(String(localized: "Your account was deleted")).post()
        case .idle, .deleting:
            break
        }
    }
}

#Preview {
    DeleteAccountSheet(
        viewModel: AccountDeletionViewModel(
            deleteAccount: DeleteAccountUseCase(repository: PreviewAccountDeletionRepository(), feedCache: nil)),
        onClose: {}
    )
}

/// A preview deletes nothing and asks nobody.
private struct PreviewAccountDeletionRepository: AccountDeletionRepository {
    func deleteAccount(authorizationCode: String?) async throws {}
}
