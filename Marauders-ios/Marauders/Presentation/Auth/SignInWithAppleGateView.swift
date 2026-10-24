//
//  SignInWithAppleGateView.swift
//  Marauders
//

import AuthenticationServices
import SwiftUI

struct SignInWithAppleGateView: View {
    @Bindable var authViewModel: AuthViewModel
    @State private var locationGate = SignInLocationViewModel()
    @State private var countryOverride: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    let navigationTitle: String
    let systemImage: String
    let title: String
    let subtitle: String
    let accessibilityIdentifier: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    if let code = locationGate.countryCode {
                        let selectedCode = countryOverride ?? code
                        NavigationLink {
                            CountryPickerView(selection: Binding(
                                get: { countryOverride ?? code },
                                set: { countryOverride = $0 }
                            ))
                        } label: {
                            HStack {
                                Text("Country")
                                Spacer()
                                Text("\(Country.flagEmoji(for: selectedCode)) \(CountryCatalog.name(for: selectedCode))")
                                Image(systemName: "chevron.right").font(.footnote)
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityIdentifier("signin.country")
                    }
                    if locationGate.isResolving { ProgressView() }
                    if let message = locationGate.message {
                        Text(message).font(.subheadline).multilineTextAlignment(.center)
                    }
                    if !locationGate.canSignIn && !locationGate.isResolving {
                        Button(locationGate.needsSettings ? "Open Settings" : "Allow Always location / Try again") {
                            if locationGate.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            } else { locationGate.begin() }
                        }
                        .accessibilityIdentifier("signin.allowLocation")
                    }
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    locationGate.refresh()
                    guard locationGate.canSignIn, let code = locationGate.countryCode else { return }
                    authViewModel.selectedCountryCode = countryOverride ?? code
                    authViewModel.handleAuthorization(result)
                }
                .disabled(!locationGate.canSignIn)
                .accessibilityIdentifier("signin.apple")
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: 320, minHeight: 48, maxHeight: 48)
                .padding(.top, 8)

                #if DEBUG
                if AppRuntimeConfiguration.isUITesting {
                    Button("Complete test sign in") {
                        if let code = locationGate.countryCode {
                            authViewModel.selectedCountryCode = countryOverride ?? code
                            authViewModel.completeUITestSignIn()
                        }
                    }
                        .disabled(!locationGate.canSignIn)
                        .accessibilityIdentifier("auth.completeUITestSignIn")
                }
                #endif

                if let errorMessage = authViewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .task { locationGate.begin() }
        .onDisappear { locationGate.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { locationGate.begin() }
        }
    }
}
