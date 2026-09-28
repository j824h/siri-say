import NaturalLanguage

// Keep the recognizer's language tag (including Chinese script tags) so that
// sentence-context routing can still distinguish Mandarin and Cantonese later.
func availableDetectedLanguage(
    hypotheses: [String: Double],
    installedLanguages: [String],
    fallbackLanguage: String?
) -> String? {
    let ranked = hypotheses.filter { $0.value.isFinite && $0.value > 0 && $0.key != "und" }
        .sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }

    func isInstalled(_ language: String) -> Bool {
        let tag: String
        switch language.lowercased() {
        case "yue", "yue-hk": tag = "zh-HK"
        case "cmn", "cmn-cn", "cmn-tw": tag = "zh-CN"
        default: tag = language
        }
        return installedLanguages.contains { affinity(detected: tag, voice: $0) != nil }
    }

    if let candidate = ranked.first(where: { isInstalled($0.key) }) {
        return candidate.key
    }
    // Leave unrecognized input to the caller's previous-sentence handling.
    guard let best = ranked.first else { return nil }
    if let fallbackLanguage, isInstalled(fallbackLanguage) {
        return fallbackLanguage
    }
    // Preserve the best guess for an actionable missing-voice error when even
    // the configured Siri language has no installed voice.
    return best.key
}

func detectAvailableLanguage(
    _ text: String,
    installedLanguages: [String],
    fallbackLanguage: String?,
    debugEnabled: Bool
) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let hypotheses = Dictionary(uniqueKeysWithValues:
        recognizer.languageHypotheses(withMaximum: 100).map { ($0.key.rawValue, $0.value) }
    )
    let selected = availableDetectedLanguage(
        hypotheses: hypotheses,
        installedLanguages: installedLanguages,
        fallbackLanguage: fallbackLanguage
    )
    if debugEnabled {
        let ranked = hypotheses.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        debug(true, "language hypotheses [\(ranked)]; selected \(selected ?? "undetermined")")
    }
    return selected
}
