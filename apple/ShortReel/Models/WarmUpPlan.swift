import Foundation
import SwiftData

@Model
final class WarmUpPlan {
    var platform: Platform
    var niche: String
    var startDate: Date
    var lastSessionMinutes: Int
    var lastItemsToView: Int
    var persona: Persona?

    init(
        platform: Platform,
        niche: String = "",
        startDate: Date = .now,
        lastSessionMinutes: Int = 20,
        lastItemsToView: Int = 10,
        persona: Persona? = nil
    ) {
        self.platform = platform
        self.niche = niche
        self.startDate = startDate
        self.lastSessionMinutes = lastSessionMinutes
        self.lastItemsToView = lastItemsToView
        self.persona = persona
    }

    var dayIndex: Int {
        max(Calendar.current.dateComponents([.day], from: startDate, to: .now).day ?? 0, 0) + 1
    }

    var currentPhaseIndex: Int {
        WarmUpPlaybook.phaseIndex(for: platform, day: dayIndex)
    }
}
