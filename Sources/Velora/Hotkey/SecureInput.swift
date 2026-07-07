import Carbon.HIToolbox
import Foundation

/// Secure keyboard entry detection (password fields, some terminals).
/// When active, Velora refuses to record: hotkey events are unreliable and
/// inserting into a secure field is wrong (docs/SPEC.md).
enum SecureInput {
    /// True while any process holds secure event input (e.g. a focused
    /// password field).
    static var isActive: Bool {
        IsSecureEventInputEnabled()
    }
}
