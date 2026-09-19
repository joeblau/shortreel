import SwiftData

extension PersistentModel {
    /// True while the model can still be read safely.
    ///
    /// `isDeleted` only covers the window between `delete` and `save`. Once
    /// the save lands, the instance is detached (`modelContext == nil`) and
    /// reading any persisted property traps. Views that may re-render during
    /// a removal transition must check this before touching anything else.
    var isLive: Bool {
        !isDeleted && modelContext != nil
    }
}
