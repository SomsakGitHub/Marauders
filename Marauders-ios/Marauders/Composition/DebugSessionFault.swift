//
//  DebugSessionFault.swift
//  Marauders
//

#if DEBUG
    import Foundation
    import MaraudersAuth

    /// A way to meet a rejected access token with a real session on a real phone. Launched with
    /// `DEBUG_INVALIDATE_ACCESS_TOKEN`, the app swaps the stored access token for one that cannot pass for a live
    /// one, so the first request that carries it is answered 401 and trades the stored refresh token for a new
    /// pair: the rotation that the tests of the Worker and of the app can only stand in for.
    ///
    /// Debug builds only. A Release build has neither this code nor the launch argument's text.
    enum DebugSessionFault {
        static let launchArgument = "DEBUG_INVALIDATE_ACCESS_TOKEN"

        /// Long enough to pass `APIAccessTokenFormat.isValid`, so the clients still attach it, and not a JWT, so the
        /// Worker rejects it and `APIAccessTokenExpiry` reads it as expired.
        private static let invalidatedAccessToken = "debug-invalidated-access-token"

        /// With the launch argument present and an access token stored, replaces it with one the Worker will reject
        /// (valid format, not a real JWT). Returns whether it did.
        @discardableResult
        static func applyIfRequested(
            arguments: [String] = ProcessInfo.processInfo.arguments,
            tokenStore: any APIAccessTokenStore = KeychainAPIAccessTokenStore()
        ) -> Bool {
            guard arguments.contains(launchArgument), tokenStore.loadAccessToken() != nil else { return false }
            do {
                try tokenStore.saveAccessToken(invalidatedAccessToken)
            } catch {
                AppLog.error("auth", "debug fault: the access token could not be replaced")
                return false
            }
            AppLog.warning("auth", "debug fault: access token replaced by \(launchArgument), expect a refresh")
            return true
        }
    }
#endif
