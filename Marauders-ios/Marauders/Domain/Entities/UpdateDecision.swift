//
//  UpdateDecision.swift
//  Marauders
//

import Foundation

/// Whether this build may go on running, or must stop and send the viewer to update (docs/adr/012-force-update.md).
enum UpdateDecision: Equatable, Sendable {
    case allowed
    case required(updateURL: URL)

    /// The rule. An update is required only when every one of these holds, checked in this order, and the answer is
    /// `.allowed` at the first one that does not (the gate fails open on everything it cannot be sure of):
    /// - there is a config, and its `minimumBuild` is above 0;
    /// - its link is official (`isOfficialUpdateURL`), so the screen never offers a way off Apple's domains;
    /// - this build's own number is known and this is not a debug build (a debug build is never stopped; build 1, the
    ///   number of every local build, is stopped like any other since 2026-11-22);
    /// - the number is below the minimum (a build equal to the minimum is allowed).
    static func decide(config: AppConfig?, currentBuild: Int?, isDebugBuild: Bool) -> UpdateDecision {
        guard let config, config.minimumBuild > 0,
            let updateURL = config.updateURL, isOfficialUpdateURL(updateURL),
            let currentBuild, !isDebugBuild,
            currentBuild < config.minimumBuild
        else {
            return .allowed
        }
        return .required(updateURL: updateURL)
    }

    /// Whether `url` is an `https` link on `apple.com` or one of its subdomains, with no user, password or port. Scheme
    /// and host are compared in lower case. This is the only check of the link: Firebase serves whatever the console
    /// holds, so a minimum above 0 with any other link stops no one.
    static func isOfficialUpdateURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
            url.user?.isEmpty ?? true, url.password?.isEmpty ?? true, url.port == nil,
            let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }
}
