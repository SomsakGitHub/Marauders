//
//  DevLogin.swift
//  Marauders
//

#if DEBUG
    import Foundation

    /// Signs in a named test user through `/v1/auth/dev`, for the Simulator where Sign in with Apple has no account.
    /// The Worker answers 404 unless `DEV_LOGIN_SECRET` is set there. While there is one backend (ADR 010) that is the
    /// production Worker, the one the Debug builds talk to; a staging Worker, once there is one, is where it belongs.
    /// Compiled into debug builds only.
    enum DevLogin {
        static let userIDPrefix = "dev:"
        private static let secretKey = "MARAUDERS_DEV_LOGIN_SECRET"
        private static let labelKey = "MARAUDERS_DEV_LOGIN_LABEL"

        /// The debug app's launch environment (`SIMCTL_CHILD_MARAUDERS_DEV_LOGIN_SECRET=… xcrun simctl launch …`), else
        /// the `DEV_LOGIN_SECRET` in `backend/.dev.vars.production` of this checkout, the vars file of the environment
        /// the Debug builds use (`backend/test/scripts/iosEnvironments.test.mjs` keeps the two in step). It is never
        /// stored in the project. Whichever way it was found, it is offered only while the app talks to the host its
        /// build configured (`offeredSecret`): with an override of the base URL, or with no usable base URL at all,
        /// there is no secret.
        static var secret: String? {
            #if targetEnvironment(simulator)
                let found: String?
                if let value = ProcessInfo.processInfo.environment[secretKey], !value.isEmpty {
                    found = value
                } else {
                    found = localWorkerSecret
                }
                return offeredSecret(found, source: (try? APIBaseURL.resolved().source) ?? .override)
            #else
                return nil
            #endif
        }

        /// The secret, only when the app talks to the host its build configured and the secret is not empty. A run
        /// pointed elsewhere by the `MARAUDERS_API_BASE_URL` override gets none, because that variable can name any
        /// host and a host the secret was never meant for must not receive it.
        static func offeredSecret(_ secret: String?, source: APIBaseURLSource) -> String? {
            guard source == .configured, let secret, !secret.isEmpty else { return nil }
            return secret
        }

        #if targetEnvironment(simulator)
            /// A Simulator app can read the Mac's disk, and this source file's path leads to the checkout's git-ignored
            /// `backend/.dev.vars.production` (the variables of the Worker the Debug builds talk to), so a plain Run in
            /// Xcode is enough.
            private static let localWorkerSecret: String? = {
                var root = URL(fileURLWithPath: #filePath)
                // Up from DevLogin.swift: Configuration, Shared, Marauders, Marauders-ios.
                for _ in 0..<5 { root.deleteLastPathComponent() }
                let devVars = root.appendingPathComponent("backend/.dev.vars.production")
                guard let contents = try? String(contentsOf: devVars, encoding: .utf8) else { return nil }
                for line in contents.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("DEV_LOGIN_SECRET=") else { continue }
                    let value = trimmed.dropFirst("DEV_LOGIN_SECRET=".count).trimmingCharacters(
                        in: CharacterSet(charactersIn: "\"' "))
                    return value.isEmpty ? nil : value
                }
                return nil
            }()
        #endif

        /// Which test user to become; each label is one stable account.
        static var label: String {
            ProcessInfo.processInfo.environment[labelKey].flatMap { $0.isEmpty ? nil : $0 } ?? "simulator"
        }

        static var isAvailable: Bool { secret != nil }

        static func isDevUserID(_ userID: String) -> Bool {
            userID.hasPrefix(userIDPrefix)
        }
    }
#endif
