import Foundation

/// Reusable goals, not gesture scripts. Every input is still chosen from a fresh screen.
enum DeviceWorkflow: String, CaseIterable, Identifiable, Sendable {
    case clearHomeScreen, warmUp, createContent

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clearHomeScreen: "Clear Home Screen"
        case .warmUp: "Warm Up"
        case .createContent: "Create Content"
        }
    }

    var summary: String {
        switch self {
        case .clearHomeScreen: "Leave one empty Home Screen page with Instagram, YouTube, TikTok, and X in the Dock."
        case .warmUp: "Choose an agent profile, app, phase, and when to stop."
        case .createContent: "Choose a content type and configure a draft."
        }
    }

    func goal(details: String = "") -> String {
        switch self {
        case .clearHomeScreen:
            """
            Clear Home Screen. Leave exactly ONE visible Home Screen page with an empty grid: no app icons, folders, widgets, or widget stacks above the Dock. Keep Instagram, YouTube, TikTok, and X together in the Dock, with no other Dock icons. Keep all apps installed and their data intact in App Library.

            Work from fresh screenshots, one input at a time. Use observed AssistiveTouch controls to return Home. Navigate to the first Home page, then clean EVERY page from left to right, including folders and the Dock. An empty current page is not completion. Swipe LEFT (finger right-to-left) to reveal the next page to the RIGHT; swipe RIGHT to go back. After clearing a page, inspect the next page and continue until App Library is visibly reached. Do not clear App Library or Today View. A Search pill does not prove there is only one page. Note the page/folder, target, and cleanup phase.

            Prefer persistent editing (jiggle) mode: long-press visible empty wallpaper ONCE, then verify minus badges. If no empty area is available, long-press an icon and choose Edit Home Screen. If badges are already visible, do not long-press again. Tap an unwanted app's CURRENT minus badge, inspect the dialog, and choose ONLY Remove from Home Screen. Verify removal, then tap the next unwanted app's badge without leaving editing. Re-locate each badge from the new screenshot; icons rearrange. Continue across pages/folders in editing mode; re-enter only if badges disappear. In an open app menu, tap Remove App, then Remove from Home Screen after a fresh screenshot. Long-press individual apps only if badges are unavailable. Never tap page-thumbnail minus/checkmark controls to remove/hide pages. For widgets/stacks, tap their badge or use Remove Widget/Remove Stack; confirm Remove ONLY when the dialog names a widget/stack. Remove whole stacks.

            Never tap Delete App, Delete, Uninstall, Offload App, Hide and Require Face ID, or erase/reset controls. Never remove the four allowed apps or a folder containing one of them. Move allowed apps into the Dock with observed drags. If missing, add them from App Library if installed; never install or purchase apps. Cancel ambiguous removal dialogs and request input if a safe control or allowed app cannot be found. Do not hide pages as a shortcut or change existing hidden pages, Today View widgets, Lock Screen, wallpaper, or settings.

            Exit editing to let emptied pages collapse. If extra visible pages remain, inspect and clear them too; do not stop at the first empty page. Finally sweep in BOTH directions after the last layout change: establish the first Home page at the Today View/left boundary, swipe LEFT through every Home page to App Library, then swipe RIGHT back to Home. At an unchanged boundary, reverse direction and inspect; do not repeat. Verify exactly one visible Home page remains, its grid is empty, and the Dock contains only Instagram, YouTube, TikTok, and X. If page count is unclear, inspect the page overview/indicators without hiding pages, then repeat the boundary sweep. Earlier notes are not proof. Finish on that single empty Home page outside editing, dialogs, or menus. Unknown page count means continue verification.
            """
        case .warmUp:
            """
            Warm Up. Execute this warm-up session on the selected iPhone using one observed input at a time:
            \(details.trimmingCharacters(in: .whitespacesAndNewlines))
            Follow the specified persona, platform, phase limits, and stopping criterion. Stay within the listed action caps and prohibitions. If these are missing, request input before acting. Do not invent likes, follows, comments, messages, purchases, or posts beyond what the brief allows. Finish only after observing the requested stopping point.
            """
        case .createContent:
            """
            Create Content. Execute this brief on the selected iPhone using one observed input at a time:
            \(details.trimmingCharacters(in: .whitespacesAndNewlines))
            Use the specified app and source material. Request input for missing assets or essential creative choices. Save as a draft unless this brief explicitly asks to publish. Finish only after observing the requested draft or published result.
            """
        }
    }

    /// A separate completion review can return another input when cleanup is incomplete.
    static let cleanupCompletionReview = """
        COMPLETION REVIEW: Independently check the current image and observed navigation against the entire goal above. Require exactly one visible Home page, an empty grid, and only the four allowed apps in the Dock. Confirm both page boundaries after the last layout change. The Search pill, one empty screenshot, unchanged pixels, or earlier planner claims alone do not establish page count. If anything is unverified or another page has content, return ONE next action to inspect or clean it, not finished. Return finished only with evidence of the single-page result; never guess.
        """

    static let cleanupStallRecovery = """
        NAVIGATION RECOVERY: The proposed input has already left the screen unchanged twice. Choose a different input grounded in this screenshot. On an empty Home page, inspect adjacent pages: swipe LEFT to reach the page to the right/App Library, RIGHT to go back. At a boundary reverse direction. Do not repeat the stalled action or wait on a static page. Verify one empty page before finishing.
        """

    var limits: PhoneRunLimits { .init(maximumSteps: 300, maximumDuration: 3_600) }
}

struct PhoneRunLimits: Sendable {
    var maximumSteps: Int = 30
    var maximumDuration: TimeInterval = 300
}

enum ContentCreationType: String, CaseIterable, Identifiable, Sendable {
    case slideshow

    var id: String { rawValue }
    var title: String {
        switch self {
        case .slideshow: "Slideshow"
        }
    }
}

/// Form values become the explicit brief for the existing phone workflow.
struct SlideshowConfiguration: Sendable {
    var destination = "TikTok"
    var topic = ""
    var slideCount = 5
    var photoSelection = ""
    var caption = ""
    var instructions = ""

    var brief: String {
        """
        Content type: Slideshow (a swipeable photo post).
        Destination app: \(trim(destination))
        Topic: \(trim(topic))
        Number of slides: \(slideCount)
        Source photos on this iPhone: \(trim(photoSelection))
        Caption: \(trim(caption).isEmpty ? "Write a caption matching the topic." : trim(caption))
        Additional instructions: \(trim(instructions).isEmpty ? "None." : trim(instructions))
        Use the specified existing photos in the requested order. Do not generate, download, or substitute unrelated images. If the photos cannot be identified, there are too few, or the app cannot create this slideshow, request input.
        Save as a draft only. Do not publish, post, send, or schedule it. Verify the saved draft before finishing. If saving a draft is unavailable, request input.
        """
    }

    var validationMessage: String? {
        if trim(destination).isEmpty { return "Enter the destination app." }
        if trim(topic).isEmpty { return "Add a topic for your slideshow." }
        if !(2...20).contains(slideCount) { return "Choose between 2 and 20 slides." }
        if trim(photoSelection).isEmpty { return "Describe the photos to use, such as an album and their order." }
        if DeviceWorkflow.createContent.goal(details: brief).count > DevicePromptPlanner.maximumPromptLength {
            return "Shorten the slideshow details before creating the draft."
        }
        return nil
    }

    private func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
