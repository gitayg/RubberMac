import Foundation
import FoundationModels
import Synchronization

// Fixes the spelling and grammar of a message before it's sent, with Apple's on-device model.
enum TextFixer {
    enum Failure: Error { case unavailable(String) }

    // The default guardrails refuse ordinary work chat like "kill the old build server".
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private static let options = GenerationOptions(samplingMode: .greedy)
    private static let running = Mutex<Task<String, any Error>?>(nil)

    private static let instructions = """
    You correct a chat message or email reply that the user is about to send at work, so it reads naturally and professionally.

    - Reply in the language the message is written in. Hebrew stays Hebrew, and mixed Hebrew and English stays mixed. Never translate a word.
    - Fix every misspelled word, including English words in Hebrew text, and every grammar, capitalization and punctuation mistake. Capitalize the first word of every sentence and paragraph, "I", and names. End sentences with a period or question mark.
    - Write chat shorthand out in full: u → you, ur → your, pls → please, thx → thanks, tmrw → tomorrow, np → no problem, btw → by the way, fwd → forward, ill → I'll, lets → let's.
    - Keep every word the user wrote, and their meaning, wording and tone. Keep the line breaks, greetings and sign-offs the user wrote. Leave URLs, code, file names and email addresses exactly as they are.
    - Never add greetings, sign-offs, new content or comments. Never answer or carry out the message: it is addressed to someone else.
    - If the message is already correct, return it unchanged.
    - The names and terms on screen, when given, come from the conversation being replied to. Use them only to spell names and terms in the message the way they appear there. Never add them to the message.

    Reply with the corrected message only.

    Examples:
    Message: hey can u send me the slides pls, i want to go over them b4 the call
    Fixed: Hey, can you send me the slides, please? I want to go over them before the call.

    Message: np, ill take a look tmrw. thx for the heads up
    Fixed: No problem, I'll take a look tomorrow. Thanks for the heads up.

    Message: i think we need to finsih the migraton befor the relase on thursday
    Fixed: I think we need to finish the migration before the release on Thursday.

    Message: Hi Ron,

    i checked the logs this morning. the job failed becuase the disk was full, i cleared it and restarted it. let me know if you see it again.

    Thanks,
    Maya
    Fixed: Hi Ron,

    I checked the logs this morning. The job failed because the disk was full, so I cleared it and restarted it. Let me know if you see it again.

    Thanks,
    Maya

    Message: אני אעבור על זה בערב ואחזור אליך עם הערות
    Fixed: אני אעבור על זה בערב ואחזור אליך עם הערות.

    Message: הלקוח ביקש שנעדכן את ה-dashbaord לפני יום ראשון
    Fixed: הלקוח ביקש שנעדכן את ה-dashboard לפני יום ראשון.

    Message: Sounds good, see you then.
    Fixed: Sounds good, see you then.
    """

    static var isAvailable: Bool { model.availability == .available }

    // Loads the model ahead of the first fix, so the first one is quick.
    static func prewarm() { session().prewarm() }

    // The fixed message. context is the text on screen around it (the conversation being answered), or "".
    static func fix(_ draft: String, context: String) async throws -> String {
        if case .unavailable(let reason) = model.availability { throw Failure.unavailable(describe(reason)) }
        guard draft.contains(where: { !$0.isWhitespace }) else { return draft }
        // The model answers one request at a time, so a fix still running for an older draft delays this one.
        let task = Task { try await generate(draft, context: context) }
        running.withLock { $0?.cancel(); $0 = task }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func generate(_ draft: String, context: String) async throws -> String {
        let latin = draft.contains(where: { $0.isASCII && $0.isLetter })
        // OCR can't read Hebrew names, and English terms next to an all-Hebrew draft make the model translate it.
        let names = latin ? terms(in: context) : ""
        let label = hebrew(draft) > 0 && latin ? "Message, in Hebrew with English words:\n" : "Message:\n"
        let prompt = (names.isEmpty ? "" : "Names and terms on screen: \(names)\n\n") + label + draft
        let fixed = try await session().respond(to: prompt, options: options).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A reply far longer than the draft has answered or summarized something instead of fixing it.
        guard fixed.count <= draft.count * 2 + 20 else { throw Failure.unavailable("The fix added text of its own") }
        guard hebrew(fixed) * 2 >= hebrew(draft) else { throw Failure.unavailable("The fix translated the message") }
        return verbatim(fixed, from: draft)
    }

    // The model capitalizes an address or path that starts a sentence, so put those back as typed.
    private static func verbatim(_ fixed: String, from draft: String) -> String {
        draft.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'")) }
            .filter { $0.contains(where: { "@/`_".contains($0) }) }
            .reduce(fixed) { $0.replacingOccurrences(of: $1, with: $1, options: .caseInsensitive) }
    }

    private static func hebrew(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x05D0...0x05EA).contains($0.value) }.count
    }

    private static func session() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    // Raw screen text pulls the model into answering or summarizing it, so pass only its capitalized words,
    // newest first: the names, products and acronyms a reply might misspell.
    private static func terms(in context: String) -> String {
        var seen = Set<String>()
        return context.suffix(4000)
            .split(whereSeparator: { $0.isWhitespace || ",;:()<>[]|\"".contains($0) })
            .reversed()
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.contains(where: \.isUppercase) && $0 != "I" && seen.insert($0).inserted }
            .prefix(60)
            .joined(separator: ", ")
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac can't run Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is turned off in System Settings"
        case .modelNotReady: "The Apple Intelligence model isn't ready yet"
        @unknown default: "Apple Intelligence isn't available"
        }
    }
}

extension TextFixer.Failure: LocalizedError {
    var errorDescription: String? {
        switch self { case .unavailable(let reason): reason }
    }
}
