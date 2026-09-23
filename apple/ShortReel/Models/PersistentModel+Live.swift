import SwiftData

extension PersistentModel {
    var isLive: Bool {
        !isDeleted && modelContext != nil
    }
}
