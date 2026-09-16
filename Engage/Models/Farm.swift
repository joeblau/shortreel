import Foundation
import SwiftData

@Model
final class Farm {
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Account.farm)
    var accounts: [Account] = []

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}
