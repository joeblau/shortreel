import Foundation
import SwiftData

@Model
final class Farm {
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Persona.farm)
    var personas: [Persona] = []

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}
