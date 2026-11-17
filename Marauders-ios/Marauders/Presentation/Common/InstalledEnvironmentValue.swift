//
//  InstalledEnvironmentValue.swift
//  Marauders
//

/// A value the composition root puts in the environment and a view cannot do without.
///
/// A Debug build stops when it is missing, so a window or preview that forgot it shows up at once; a Release build
/// carries on with `fallback`, a value that stands alone.
@MainActor
func installedValue<Value>(_ value: Value?, forKey key: String, fallback: () -> Value) -> Value {
    if let value { return value }
    assertionFailure("Nothing installed for \(key): add .environment(\(key), …) above this view")
    return fallback()
}
