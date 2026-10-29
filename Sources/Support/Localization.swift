import Foundation

enum AppLanguage: String, CaseIterable {
    case en, ja, zh = "zh-Hans"
    var name: String { switch self { case .en: return "English"; case .ja: return "日本語"; case .zh: return "简体中文" } }
    var voiceCode: String { self == .zh ? "zh" : rawValue }
}
enum LanguageMode: String, CaseIterable, Identifiable {
    case system, en, ja, zh = "zh-Hans"
    var id: String { rawValue }
}
struct LocalizedMessage: ExpressibleByStringLiteral {
    let key: String
    let arguments: [String]
    init(_ key: String, _ arguments: [String] = []) { self.key = key; self.arguments = arguments }
    init(stringLiteral value: String) { self.init(value) }
}
struct Localizer {
    var mode: LanguageMode = .system
    var preferredLanguages: [String] = Locale.preferredLanguages
    static func resolve(_ preferences: [String]) -> AppLanguage {
        for preference in preferences {
            switch preference.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first {
            case "zh": return .zh
            case "ja": return .ja
            case "en": return .en
            default: continue
            }
        }
        return .en
    }
    var language: AppLanguage { mode == .system ? Self.resolve(preferredLanguages) : AppLanguage(rawValue: mode.rawValue) ?? .en }
    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return (language, bundle)
    })
    func text(_ key: String, _ arguments: [String] = []) -> String {
        let fallback = Self.bundles[.en]?.localizedString(forKey: key, value: key, table: nil) ?? key
        let format = Self.bundles[language]?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments.map { $0 as CVarArg })
    }
    func text(_ message: LocalizedMessage) -> String { text(message.key, message.arguments) }
    func modeName(_ mode: LanguageMode) -> String {
        mode == .system ? text("language.system", [text("language.name." + Self.resolve(preferredLanguages).voiceCode)]) : (AppLanguage(rawValue: mode.rawValue)?.name ?? "English")
    }
}

func runLocalizationTests() {
    precondition(Localizer.resolve(["ja-JP", "en-US"]) == .ja)
    precondition(Localizer.resolve(["zh_Hans_CN"]) == .zh)
    precondition(Localizer.resolve(["zh-Hant-TW"]) == .zh)
    precondition(Localizer.resolve(["en-GB"]) == .en)
    precondition(Localizer.resolve(["fr-FR", "ja"]) == .ja)
    precondition(Localizer.resolve(["de-DE"]) == .en)
    precondition(Localizer.resolve([]) == .en)
    precondition(Localizer(mode: .ja, preferredLanguages: ["en-US"]).language == .ja)
    precondition(Localizer(mode: .system, preferredLanguages: ["zh-CN"]).language == .zh)
    let keys: [String] = ["language.name.en", "language.name.ja", "language.name.zh", "language.label", "language.system", "app.tagline", "poster.kicker", "poster.title", "poster.subtitle", "poster.thanks", "status.paused", "status.active", "status.preparing", "status.starting", "status.on", "status.off", "status.replay", "status.replayDone", "guard.instructions", "guard.enable", "guard.pause", "guard.preview", "guard.previewFooter", "guard.retract", "guard.escapeClose", "guard.escapePause", "guard.shortcuts", "image.caption", "image.change", "image.reset", "image.title", "image.prompt", "image.message", "privacy.local", "sensitivity.label", "sensitivity.high", "sensitivity.low", "sensitivity.medium", "sensitivity.hint", "voice.enable", "voice.label", "voice.variant", "voice.auto", "voice.audition", "camera.off", "camera.replayOff", "camera.permissionHint", "camera.counts", "camera.connecting", "camera.configuring", "camera.startingStream", "camera.occluded", "error.cameraNoFrames", "error.cameraPermission", "error.cameraDenied", "error.cameraTimeout", "error.cameraUnavailable", "error.cameraConfiguration", "error.cameraStartup", "error.cameraInterrupted", "error.cameraRuntime", "error.cameraDetails", "error.handDetection", "error.replayEmpty", "error.replayRead", "error.voiceLoad", "error.voicePlay", "settings.open", "menu.open", "menu.quit", "menu.about", "menu.quitApp", "motion.waiting", "motion.cooldown", "motion.holding", "motion.detected", "motion.keypoints", "motion.pose", "motion.approaching", "motion.confirmed", "motion.occludedHold"]
    var counts: [String: Int] = [:]
    for language in AppLanguage.allCases {
        let strings = Localizer(mode: LanguageMode(rawValue: language.rawValue)!)
        for key in keys {
            let value = strings.text(key)
            precondition(value != key && !value.isEmpty, "Missing localization: \(language.rawValue)/\(key)")
            let count = value.components(separatedBy: "%@").count - 1
            if let baseline = counts[key] { precondition(count == baseline, "Mismatched placeholders: \(key)") }
            else { counts[key] = count }
        }
        for variant in ["a", "b", "c"] {
            guard let audio = Bundle.main.url(forResource: language.voiceCode + "-" + variant, withExtension: "wav", subdirectory: "Voices") else { preconditionFailure("Missing localized audio") }
            let bytes = try! Data(contentsOf: audio)
            precondition(bytes.count > 44 && String(data: bytes.prefix(4), encoding: .ascii) == "RIFF" && String(data: bytes[8..<12], encoding: .ascii) == "WAVE")
        }
        let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")!
        let permission = Bundle(path: path)!.localizedString(forKey: "NSCameraUsageDescription", value: "MISSING", table: "InfoPlist")
        precondition(permission != "MISSING")
        precondition(!strings.text("camera.counts", ["1","2","3"]).contains("%@"))
        precondition(strings.text("motion.approaching", ["50"]).contains("50%"))
    }
    print("PASS: system language resolution, manual override, three complete catalogs, matching format placeholders")
}
