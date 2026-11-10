import Foundation

enum MeetingNotesTemplate: String, CaseIterable, Identifiable {
    case general, standup, interview, lecture

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var prompt: String {
        switch self {
        case .general: return ""
        case .standup:
            return MeetingNotesPrompt.builtinGuidance + " Summarize progress, current work, and blockers. Include only commitments actually stated in the action items. Do not assume every participant reported all three."
        case .interview:
            return MeetingNotesPrompt.builtinGuidance + " Organize the summary around the main questions and answers. Preserve the interviewee's qualifications and uncertainty. Distinguish observations from opinions. Include decisions and actions only if explicitly discussed."
        case .lecture:
            return MeetingNotesPrompt.builtinGuidance + " Summarize the main concepts, explanations, and examples in a useful study-note structure. Preserve technical terms. Do not invent homework, decisions, or action items when none were assigned."
        }
    }

    static func matching(prompt: String) -> MeetingNotesTemplate? {
        allCases.first { $0.prompt == prompt }
    }
}
