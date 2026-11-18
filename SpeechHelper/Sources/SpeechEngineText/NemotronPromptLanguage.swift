import Foundation

/// Nemotron conditions on a language-ID prompt. A checkpoint's `prompt_dictionary`
/// maps language keys ("fr", "fr-FR", "auto", ...) to prompt indices; this applies
/// NeMo's rule to the dictation language the app sends.
public enum NemotronPromptLanguage {
    /// The key itself when the dictionary has it, else the one key the bare code
    /// prefixes ("th" -> "th-TH"). Nil, which leaves the model on its own default
    /// (`auto` for Unified), when there is no language, no such key, or more than
    /// one ("ja" with "ja-JP" and "ja-JA").
    public static func key(for language: String?, in dictionary: [String: Int]) -> String? {
        guard let language, !language.isEmpty else { return nil }
        if dictionary[language] != nil { return language }
        let prefix = language.lowercased() + "-"
        let matches = dictionary.keys.filter { $0.lowercased().hasPrefix(prefix) }
        return matches.count == 1 ? matches[0] : nil
    }
}
