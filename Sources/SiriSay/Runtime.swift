import Foundation
import NaturalLanguage
import AVFoundation
import Darwin
import ObjectiveC

typealias AudioHandler = @convention(block) (NSData) -> Void
typealias WordHandler  = @convention(block) ([NSObject]) -> Void
typealias DynamicPromptHandler = @convention(block) (NSString?, NSString?) -> Void
// SiriTTS upstream defines the private issue callback with this shape.
typealias IssueHandler = @convention(block) (Any?) -> Void

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("siri-say: \(message)\n").utf8))
    // SiriTTSSynthesisEngine teardown is process-global and crash/hang-prone.
    // _exit() terminates without running normal process teardown.
    Darwin._exit(1)
}

func debug(_ enabled: Bool, _ message: @autoclosure () -> String) {
    guard enabled else { return }
    FileHandle.standardError.write(Data(("siri-say: \(message())\n").utf8))
}

let framework =
    "/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService"
let assistantServicesFramework =
    "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/AssistantServices"

func loadFrameworks() {
    guard dlopen(framework, RTLD_LAZY) != nil else {
        die("cannot load SiriTTSService: \(String(cString: dlerror()))")
    }
    guard dlopen(assistantServicesFramework, RTLD_LAZY) != nil else {
        die("cannot load AssistantServices: \(String(cString: dlerror()))")
    }
}

struct Voice: Hashable {
    let specifier: String
    let language: String
    let name: String
    let kind: String
    let footprint: String
    let gender: String?
    let path: URL
}

func discoverVoices() -> [Voice] {
    let roots = [
        "/System/Library/AssetsV2/com_apple_MobileAsset_Trial_Siri_SiriTextToSpeech/purpose_auto",
        "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto",
    ]

    let prefix = "com.apple.siri.tts.voice."
    let fm = FileManager.default
    var voices: [Voice] = []
    var seen = Set<String>()

    for root in roots {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)

        guard let assets = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }

        for asset in assets where asset.pathExtension == "asset" {
            let assetData = asset.appendingPathComponent("AssetData", isDirectory: true)
            guard fm.fileExists(atPath: assetData.path) else { continue }

            let infoURL = asset.appendingPathComponent("Info.plist")
            guard
                let data = try? Data(contentsOf: infoURL),
                let object = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                ),
                let plist = object as? [String: Any],
                let properties = plist["MobileAssetProperties"] as? [String: Any],
                let specifier =
                    (properties["Factor"] as? String)
                    ?? (properties["AssetSpecifier"] as? String),
                specifier.hasPrefix(prefix)
            else {
                continue
            }

            let fields = specifier
                .dropFirst(prefix.count)
                .split(separator: ".")
                .map(String.init)

            guard fields.count >= 4 else { continue }

            let language = fields[0].replacingOccurrences(of: "_", with: "-")
            let voice = Voice(
                specifier: specifier,
                language: language,
                name: fields[1],
                kind: fields[2],
                footprint: fields[3],
                gender: properties["gender"] as? String,
                path: asset
            )

            // The two MobileAsset roots can expose the same logical voice.
            let key = "\(voice.language)|\(voice.name)|\(voice.kind)|\(voice.footprint)"
            if seen.insert(key).inserted {
                voices.append(voice)
            }
        }
    }

    return voices.sorted {
        ($0.language, $0.name, $0.kind, $0.footprint)
            < ($1.language, $1.name, $1.kind, $1.footprint)
    }
}

let voices = discoverVoices()

// System Settings gets the user-facing voice label from AssistantServices.
// Do not infer picker numbers or construct locale-specific labels ourselves.
private let voiceLocalization: NSObject? = {
    guard let cls = NSClassFromString("AFLocalization") as? NSObject.Type else {
        return nil
    }
    return cls.init()
}()

private typealias OutputVoiceDescriptorFn = @convention(c) (
    AnyObject, Selector, NSString, NSString
) -> Unmanaged<AnyObject>?

private var pickerLabelCache: [String: String] = [:]
private var pickerVoiceNameCache: [String: String] = [:]

private func descriptorLabel(language: String, voiceName: String) -> String? {
    guard
        let localization = voiceLocalization,
        let cls = NSClassFromString("AFLocalization")
    else {
        return nil
    }

    let sel = NSSelectorFromString(
        "outputVoiceDescriptorForOutputLanguageCode:voiceName:"
    )
    guard let method = class_getInstanceMethod(cls, sel) else {
        return nil
    }

    let fn = unsafeBitCast(
        method_getImplementation(method),
        to: OutputVoiceDescriptorFn.self
    )

    guard
        let descriptor = fn(
            localization,
            sel,
            language as NSString,
            voiceName as NSString
        )?.takeUnretainedValue() as? NSObject,
        let label = descriptor.value(forKey: "localizedDisplay") as? String,
        !label.isEmpty
    else {
        return nil
    }

    return label
}

// Some installed TTS assets are implementation assets rather than picker names.
// neuralAX Tara is one example: its own voice_configs.plist declares the
// locale's picker voice names by gender (female -> riya, male -> akash).
// Only use this asset-owned alias when the asset name itself has no descriptor.
private func pickerVoiceName(for voice: Voice) -> String {
    let key = "\(voice.language)|\(voice.name)|\(voice.kind)|\(voice.footprint)"
    if let cached = pickerVoiceNameCache[key] {
        return cached
    }

    if descriptorLabel(language: voice.language, voiceName: voice.name) != nil {
        pickerVoiceNameCache[key] = voice.name
        return voice.name
    }

    guard let gender = voice.gender?.lowercased() else {
        pickerVoiceNameCache[key] = voice.name
        return voice.name
    }

    let configURL = voice.path
        .appendingPathComponent("AssetData", isDirectory: true)
        .appendingPathComponent("voice_configs.plist")

    guard
        let data = try? Data(contentsOf: configURL),
        let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ),
        let plist = object as? [String: Any],
        let aliases = plist["_voices"] as? [String: Any],
        let alias = aliases[gender] as? String,
        descriptorLabel(language: voice.language, voiceName: alias) != nil
    else {
        pickerVoiceNameCache[key] = voice.name
        return voice.name
    }

    pickerVoiceNameCache[key] = alias
    return alias
}

func pickerLabel(for voice: Voice) -> String? {
    let pickerName = pickerVoiceName(for: voice)
    let key = "\(voice.language)|\(pickerName)"
    if let cached = pickerLabelCache[key] {
        return cached
    }

    guard let label = descriptorLabel(
        language: voice.language,
        voiceName: pickerName
    ) else {
        return nil
    }

    pickerLabelCache[key] = label
    return label
}


private typealias NoArgumentClassFn = @convention(c) (
    AnyClass, Selector
) -> Unmanaged<AnyObject>?

private typealias OneStringInstanceFn = @convention(c) (
    AnyObject, Selector, NSString
) -> Unmanaged<AnyObject>?

private typealias TwoStringClassFn = @convention(c) (
    AnyClass, Selector, NSString, NSString
) -> Unmanaged<AnyObject>?

private func classObject(
    className: String,
    selectorName: String
) -> AnyObject? {
    guard let cls: AnyClass = NSClassFromString(className) else { return nil }
    let sel = NSSelectorFromString(selectorName)
    guard let method = class_getClassMethod(cls, sel) else { return nil }

    let fn = unsafeBitCast(
        method_getImplementation(method),
        to: NoArgumentClassFn.self
    )
    return fn(cls, sel)?.takeUnretainedValue()
}

private func instanceObject(
    _ object: AnyObject,
    className: String,
    selectorName: String,
    argument: String
) -> AnyObject? {
    guard let cls: AnyClass = NSClassFromString(className) else { return nil }
    let sel = NSSelectorFromString(selectorName)
    guard let method = class_getInstanceMethod(cls, sel) else { return nil }

    let fn = unsafeBitCast(
        method_getImplementation(method),
        to: OneStringInstanceFn.self
    )
    return fn(object, sel, argument as NSString)?.takeUnretainedValue()
}

private func outputVoiceIdentifier(
    language: String,
    voiceName: String
) -> String? {
    guard let cls: AnyClass = NSClassFromString("AFVoiceInfo") else { return nil }
    let sel = NSSelectorFromString(
        "outputVoiceIdentifierForLanguageCode:voiceName:"
    )
    guard let method = class_getClassMethod(cls, sel) else { return nil }

    let fn = unsafeBitCast(
        method_getImplementation(method),
        to: TwoStringClassFn.self
    )
    return fn(
        cls,
        sel,
        language as NSString,
        voiceName as NSString
    )?.takeUnretainedValue() as? String
}

private func pickerVoiceName(
    from outputVoice: AnyObject?,
    language: String
) -> String? {
    guard let outputVoice else { return nil }

    // Some AssistantServices APIs return AFVoiceInfo directly.
    if let object = outputVoice as? NSObject,
       object.responds(to: NSSelectorFromString("name")),
       let name = object.value(forKey: "name") as? String,
       !name.isEmpty
    {
        return name
    }

    // Others expose the canonical output-voice identifier string. Resolve it
    // through AFVoiceInfo rather than parsing or guessing its suffix.
    guard let identifier = outputVoice as? String else { return nil }

    let pickerNames = Set(
        voices
            .filter { affinity(detected: language, voice: $0.language) != nil }
            .map(pickerVoiceName(for:))
    )

    for name in pickerNames {
        if name.caseInsensitiveCompare(identifier) == .orderedSame {
            return name
        }

        guard let candidate = outputVoiceIdentifier(
            language: language,
            voiceName: name
        ) else {
            continue
        }
        if candidate.caseInsensitiveCompare(identifier) == .orderedSame {
            return name
        }
    }

    return nil
}

private let currentSiriSettings: (language: String, voiceName: String?)? = {
    guard
        let language = classObject(
            className: "AFConnection",
            selectorName: "currentLanguageCode"
        ) as? String,
        !language.isEmpty
    else {
        return nil
    }

    let outputVoice = classObject(
        className: "AFConnection",
        selectorName: "outputVoice"
    )
    return (
        language,
        pickerVoiceName(from: outputVoice, language: language)
    )
}()

private func appleDefaultPickerVoiceName(for language: String) -> String? {
    guard let localization = voiceLocalization else { return nil }
    let outputVoice = instanceObject(
        localization,
        className: "AFLocalization",
        selectorName: "defaultOutputVoiceForSiriSessionLanguage:",
        argument: language
    )
    return pickerVoiceName(from: outputVoice, language: language)
}

private func preferredPickerVoiceName(
    for language: String,
    allowCurrentSiriBaseLanguage: Bool
) -> (name: String, source: String)? {
    if let current = currentSiriSettings,
       let voiceName = current.voiceName,
       let score = affinity(detected: language, voice: current.language),
       score <= (allowCurrentSiriBaseLanguage ? 2 : 1)
    {
        return (voiceName, "System Settings")
    }

    if let name = appleDefaultPickerVoiceName(for: language) {
        return (name, "Apple locale default")
    }

    return nil
}

func friendlyVoiceName(_ name: String) -> String {
    // Humanize simple internal tokens (tara -> Tara) without mangling structured
    // identifiers such as en-US-G, zh-CN-D, or th-TH-B.
    guard name.unicodeScalars.allSatisfy({
        CharacterSet.lowercaseLetters.contains($0)
    }) else {
        return name
    }

    guard let first = name.first else { return name }
    return first.uppercased() + String(name.dropFirst())
}

func voiceMatchesRequest(_ voice: Voice, request: String) -> Bool {
    if voice.name.caseInsensitiveCompare(request) == .orderedSame {
        return true
    }

    let friendly = friendlyVoiceName(voice.name)
    if friendly.caseInsensitiveCompare(request) == .orderedSame {
        return true
    }

    guard let label = pickerLabel(for: voice) else {
        return false
    }
    return label.caseInsensitiveCompare(request) == .orderedSame
}

func terminalCellWidth(_ string: String) -> Int {
    string.unicodeScalars.reduce(into: 0) { width, scalar in
        let w = wcwidth(wchar_t(scalar.value))
        if w > 0 {
            width += Int(w)
        }
    }
}

func paddedForTerminal(_ string: String, to width: Int) -> String {
    string + String(
        repeating: " ",
        count: max(0, width - terminalCellWidth(string))
    )
}

func resourceAssetPath(for voice: Voice) -> URL? {
    let roots = [
        "/System/Library/AssetsV2/com_apple_MobileAsset_Trial_Siri_SiriTextToSpeech/purpose_auto",
        "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto",
    ]
    let target = "com.apple.siri.tts.resource."
        + voice.language.replacingOccurrences(of: "-", with: "_")
    let fm = FileManager.default

    for root in roots {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let assets = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }

        for asset in assets where asset.pathExtension == "asset" {
            let infoURL = asset.appendingPathComponent("Info.plist")
            guard
                let data = try? Data(contentsOf: infoURL),
                let object = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                ),
                let plist = object as? [String: Any],
                let properties = plist["MobileAssetProperties"] as? [String: Any],
                let specifier =
                    (properties["Factor"] as? String)
                    ?? (properties["AssetSpecifier"] as? String)
            else {
                continue
            }

            if specifier.caseInsensitiveCompare(target) == .orderedSame {
                return asset.appendingPathComponent("AssetData", isDirectory: true)
            }
        }
    }

    return nil
}

func baseLanguage(_ tag: String) -> String {
    tag.split(separator: "-", maxSplits: 1).first.map(String.init) ?? tag
}

func affinity(detected: String, voice: String) -> Int? {
    if detected.caseInsensitiveCompare(voice) == .orderedSame {
        return 0
    }

    let d = detected.lowercased()
    let v = voice.lowercased()

    guard baseLanguage(d) == baseLanguage(v) else { return nil }
    return 2
}

private enum ChineseSpokenVariant: String {
    case mandarin
    case cantonese
}

private enum ChineseWrittenClass: String {
    case cantonese
    case swc
    case mixed
    case neutral
}

private struct ChineseEvidence {
    let classification: ChineseWrittenClass
    let cantoneseCount: Int
    let swcCount: Int
    let hanCount: Int
}

// Written-Cantonese/SWC feature inventory and decision rule ported from
// CanCLID/cantonesedetect, accompanying Lau, Lau & To (LREC-COLING 2024),
// "The Extraction and Fine-grained Classification of Written Cantonese
// Materials through Linguistic Feature Detection".
//
// The important property for us is that script is *not* treated as spoken
// variety: the classifier looks for lexical/grammatical evidence and can return
// Mixed or Neutral when the sentence itself does not decide the issue.
// https://aclanthology.org/2024.eurali-1.4/
// https://github.com/CanCLID/cantonesedetect
private let cantoneseFeatureRegex = try! NSRegularExpression(
    pattern:
        #"[嘅嗰啲咗佢喺咁噉冇哋畀嚟諗惗乜嘢閪撚𨳍𨳊瞓睇餸𨋢摷嚿嚡嘥嗮啱揾搵揦喐逳噏𢳂岋糴揈捹撳㩒𥄫攰癐冚孻冧𡃁嚫跣𨃩瀡氹嬲掟揼揸孭黐唞㪗埞忟𢛴踎脷]|[㗎𠺢喎噃啩𠿪啫唧嗱]|唔[係得會想好識使洗駛通知到去走掂該錯差多少]|點[樣會做得解知]|[琴尋噚聽第]日|[而依]家|[真就實梗緊堅又話都但淨剩只定一]係|邊[度個位科]|[嚇凍攝整揩逢淥浸激][親嚫]|[橫搞傾得唔好]掂|仲[有係話要得好衰唔]|返[學工去翻番到]|[好得]返|執[好生實返輸]|[癡痴][埋線住起身]|[同帶做整溝炒煮]埋|[剩淨坐留]低|傾[偈計]|屋企|收皮|慳錢|屈機|隔籬|幫襯|求其|家陣|仆街|是[但旦]|[濕溼]碎|零舍|肉[赤緊酸]|核突|[勁隻][秋抽]|[呃𧦠][鬼人秤稱錢]"#
)

private let cantoneseExcludeRegex = try! NSRegularExpression(
    pattern: #"(關係|吱唔|咿唔|喇嘛|喇叭|俾路支|俾斯麥)"#
)

private let swcFeatureRegex = try! NSRegularExpression(
    pattern: #"[這哪唄咱啥甭那是的他她它吧沒麼么些了卻説說吃弄把也在]|[事門塊勁花那點會]兒|而已"#
)

private let swcExcludeRegex = try! NSRegularExpression(
    pattern:
        #"亞利桑那|剎那|巴塞羅那|薩那|沙那|哈瓦那|印第安那|那不勒斯|支那|是[否日次非但旦]|[利於]是|唯命是從|頭頭是道|似是而非|自以為是|俯拾皆是|撩是鬥非|莫衷一是|唯才是用|[目綠藍紅中]的|的[士確式]|波羅的海|眾矢之的|的而且確|大眼的度|的起心肝|些[微少許小]|[淹沉浸覆湮埋沒出]沒|沒[落頂收]|神出鬼沒|了[結無斷當然哥結得解事之]|[未明]了|不得了|大不了|他[信人國日殺鄉]|[其利無排維結]他|馬耳他|他加祿|他山之石|其[它]|[酒網水貼]吧|吧[台臺枱檯]|[退忘阻]卻|卻步|[遊游小傳解學假淺眾衆訴論][説說]|[說説][話服明]|自圓其[説說]|長話短[說説]|不由分[說説]|吃[虧苦力]|弄[堂]|把[握柄持火風關鬼口嘴戲脈炮砲屁手聲]|大把|拉把|冧把|掃把|拖把|得把|加把|下把位|一把年紀|把死人聲|自把自為|兩把|三把|四把|五把|幾把|拎把|第一把|泵把|也[許門]|[非威]也|也文也武|之乎者也|維也納|空空如也|頭也不回|時也[命運]也|在[場乎下校學行任野意於望內案旁生世心線逃位即職座囚此家]|[站志旨爭所勝衰實內外念現好健存潛差弊活]在|我思故我在"#
)

private func regexMatchCount(_ regex: NSRegularExpression, in text: String) -> Int {
    regex.numberOfMatches(
        in: text,
        range: NSRange(text.startIndex..<text.endIndex, in: text)
    )
}

private func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF,
         0x4E00...0x9FFF,
         0x20000...0x2EBEF,
         0x30000...0x323AF,
         0xFA0E, 0xFA0F, 0xFA11, 0xFA13, 0xFA14,
         0xFA1F, 0xFA21, 0xFA23, 0xFA24, 0xFA27,
         0xFA28, 0xFA29, 0x3006, 0x3007:
        return true
    default:
        return false
    }
}

private func researchedChineseEvidence(in text: String) -> ChineseEvidence {
    let hanCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
        if isHanScalar(scalar) { count += 1 }
    }

    guard hanCount > 0 else {
        return ChineseEvidence(
            classification: .neutral,
            cantoneseCount: 0,
            swcCount: 0,
            hanCount: 0
        )
    }

    let cantoneseCount = max(
        0,
        regexMatchCount(cantoneseFeatureRegex, in: text)
            - regexMatchCount(cantoneseExcludeRegex, in: text)
    )
    let swcCount = max(
        0,
        regexMatchCount(swcFeatureRegex, in: text)
            - regexMatchCount(swcExcludeRegex, in: text)
    )
    let totalFeatures = cantoneseCount + swcCount

    // Defaults from CanCLID/cantonesedetect: <=1% is tolerated as noise;
    // >=3% counts as meaningful presence.
    let lackCantonese = cantoneseCount <= Int(floor(0.01 * Double(hanCount)))
    let lackSWC = swcCount <= Int(floor(0.01 * Double(hanCount)))

    if totalFeatures == 0 || (lackCantonese && lackSWC) {
        return ChineseEvidence(
            classification: .neutral,
            cantoneseCount: cantoneseCount,
            swcCount: swcCount,
            hanCount: hanCount
        )
    }

    let hasCantonese = cantoneseCount >= Int(ceil(0.03 * Double(hanCount)))
    let hasSWC = swcCount >= Int(ceil(0.03 * Double(hanCount)))
    let difference = Double(cantoneseCount - swcCount) / Double(totalFeatures)

    let classification: ChineseWrittenClass
    if difference > 0.9 && !hasSWC {
        classification = .cantonese
    } else if difference < -0.9 && !hasCantonese {
        classification = .swc
    } else {
        classification = .mixed
    }

    return ChineseEvidence(
        classification: classification,
        cantoneseCount: cantoneseCount,
        swcCount: swcCount,
        hanCount: hanCount
    )
}

private func chineseVariant(forConcreteLanguage language: String) -> ChineseSpokenVariant? {
    switch language.lowercased() {
    case "zh-hk", "yue", "yue-hk":
        return .cantonese
    case "zh-cn", "zh-sg", "zh-tw", "cmn", "cmn-cn", "cmn-tw":
        return .mandarin
    default:
        return nil
    }
}

private func language(for variant: ChineseSpokenVariant) -> String {
    variant == .cantonese ? "zh-HK" : "zh-CN"
}

// System Settings' speech UI has a generic Chinese spoken-language preference.
// AVSpeechSynthesisVoice(language: "zh") is useful only if the public speech
// stack resolves it to a concrete Mandarin/Cantonese locale. Otherwise it is
// treated as no evidence.
private let nativeChineseSpeechPreference: (variant: ChineseSpokenVariant, detail: String)? = {
    guard let voice = AVSpeechSynthesisVoice(language: "zh"),
          let variant = chineseVariant(forConcreteLanguage: voice.language)
    else {
        return nil
    }
    return (variant, "System speech: \(voice.name) [\(voice.language)]")
}()

private func currentSiriChineseVariant() -> ChineseSpokenVariant? {
    guard let current = currentSiriSettings else { return nil }
    return chineseVariant(forConcreteLanguage: current.language)
}

private struct ChineseDirectResolution {
    let variant: ChineseSpokenVariant
    let reason: String
}

private func directChineseResolution(
    text: String,
    detectedLanguage: String
) -> ChineseDirectResolution? {
    if let concrete = chineseVariant(forConcreteLanguage: detectedLanguage) {
        return ChineseDirectResolution(
            variant: concrete,
            reason: "concrete locale \(detectedLanguage)"
        )
    }

    guard baseLanguage(detectedLanguage.lowercased()) == "zh" else { return nil }

    let evidence = researchedChineseEvidence(in: text)
    switch evidence.classification {
    case .cantonese:
        return ChineseDirectResolution(
            variant: .cantonese,
            reason: "CanCLID Cantonese c=\(evidence.cantoneseCount) swc=\(evidence.swcCount) han=\(evidence.hanCount)"
        )
    case .swc:
        return ChineseDirectResolution(
            variant: .mandarin,
            reason: "CanCLID SWC c=\(evidence.cantoneseCount) swc=\(evidence.swcCount) han=\(evidence.hanCount)"
        )
    case .mixed, .neutral:
        return nil
    }
}

private func fallbackChineseResolution(
    detectedLanguage: String
) -> (variant: ChineseSpokenVariant, reason: String) {
    if let native = nativeChineseSpeechPreference {
        return (native.variant, native.detail)
    }

    if let siriVariant = currentSiriChineseVariant() {
        return (siriVariant, "current Siri Chinese locale")
    }

    // Script is only a late fallback. It must not override lexical evidence or
    // local discourse context. Traditional script is deliberately not mapped
    // to Cantonese; Simplified merely supplies a final Mandarin bias.
    if detectedLanguage.lowercased() == "zh-hans" {
        return (.mandarin, "Simplified-script fallback")
    }

    return (.mandarin, "ambiguous; Mandarin fallback")
}

func resolvedChineseLanguage(
    text: String,
    detectedLanguage: String,
    debugEnabled: Bool
) -> String {
    guard baseLanguage(detectedLanguage.lowercased()) == "zh"
            || chineseVariant(forConcreteLanguage: detectedLanguage) != nil
    else {
        return detectedLanguage
    }

    if let direct = directChineseResolution(
        text: text,
        detectedLanguage: detectedLanguage
    ) {
        let resolved = language(for: direct.variant)
        debug(
            debugEnabled,
            "Chinese routing \(detectedLanguage) -> \(resolved) [\(direct.reason)]"
        )
        return resolved
    }

    let fallback = fallbackChineseResolution(detectedLanguage: detectedLanguage)
    let resolved = language(for: fallback.variant)
    debug(
        debugEnabled,
        "Chinese routing \(detectedLanguage) -> \(resolved) [\(fallback.reason)]"
    )
    return resolved
}

func kindPriority(_ kind: String) -> Int {
    switch kind.lowercased() {
    case "natural": return 0
    case "neural":  return 1
    default:        return 2
    }
}

func candidateVoices(
    language: String,
    requestedName: String? = nil,
    requestedKind: String? = nil,
    allowCurrentSiriBaseLanguage: Bool = false,
    debugEnabled: Bool = false
) -> [Voice] {
    let preferred: (name: String, source: String)? = requestedName == nil
        ? preferredPickerVoiceName(
            for: language,
            allowCurrentSiriBaseLanguage: allowCurrentSiriBaseLanguage
        )
        : nil

    if let preferred {
        debug(
            debugEnabled,
            "default logical voice for \(language): \(preferred.name) "
            + "[\(preferred.source)]"
        )
    }

    let candidates = voices.compactMap { voice -> (Voice, Int, Int)? in
        guard let score = affinity(detected: language, voice: voice.language) else {
            return nil
        }

        if let requestedName,
           !voiceMatchesRequest(voice, request: requestedName) {
            return nil
        }

        if let requestedKind,
           voice.kind.caseInsensitiveCompare(requestedKind) != .orderedSame {
            return nil
        }

        let logicalVoicePenalty: Int
        if let preferred {
            logicalVoicePenalty = pickerVoiceName(for: voice)
                .caseInsensitiveCompare(preferred.name) == .orderedSame ? 0 : 1
        } else {
            logicalVoicePenalty = 0
        }

        return (voice, score, logicalVoicePenalty)
    }

    return candidates.sorted {
        if $0.1 != $1.1 {
            return $0.1 < $1.1
        }

        // Choose the user's configured Siri voice (or Apple's locale default)
        // before choosing among internal implementation formats.
        if $0.2 != $1.2 {
            return $0.2 < $1.2
        }

        // Natural is the default implementation when the same logical voice
        // is available in multiple working formats. --kind remains the explicit
        // override.
        let ak = kindPriority($0.0.kind)
        let bk = kindPriority($1.0.kind)
        if ak != bk { return ak < bk }

        // This is only a deterministic final fallback when AssistantServices
        // did not resolve a usable logical voice; it is not voice policy.
        let nc = $0.0.name.localizedCaseInsensitiveCompare($1.0.name)
        if nc != .orderedSame { return nc == .orderedAscending }

        return $0.0.specifier.localizedCaseInsensitiveCompare($1.0.specifier)
            == .orderedAscending
    }.map(\.0)
}

func alloc(_ name: String) -> NSObject {
    guard let cls = NSClassFromString(name) as? NSObject.Type else {
        die("Objective-C class \(name) not found")
    }
    guard let obj = cls.perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue() as? NSObject
    else {
        die("could not allocate \(name)")
    }
    return obj
}


enum SiriSayError: Error, CustomStringConvertible {
    case engineInitialization(String, NSError)
    case preheat(String, NSError)
    case synthesis(String, NSError)
    case noAudio(String)

    var description: String {
        switch self {
        case let .engineInitialization(voice, error):
            return "\(voice): initialization failed: \(error.localizedDescription)"
        case let .preheat(voice, error):
            return "\(voice): preheat failed: \(error.localizedDescription)"
        case let .synthesis(voice, error):
            return "\(voice): synthesis failed: \(error.localizedDescription)"
        case let .noAudio(voice):
            return "\(voice): synthesis returned no audio"
        }
    }
}

final class EnginePool {
    // SiriTTS upstream found engine teardown to be process-global and crash-prone.
    // Keep one strongly-referenced engine per voice for the lifetime of the process.
    private var engines: [URL: NSObject] = [:]

    func engine(for voice: Voice, debugEnabled: Bool) throws -> NSObject {
        if let cached = engines[voice.path] {
            return cached
        }

        let raw = alloc("SiriTTSSynthesisEngine")
        let sel = NSSelectorFromString("initWithVoicePath:resourcePath:error:")

        guard let method = class_getInstanceMethod(type(of: raw), sel) else {
            die("initWithVoicePath:resourcePath:error: unavailable")
        }

        typealias InitFn = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AnyObject?,
            UnsafeMutablePointer<NSObject?>?
        ) -> NSObject

        let fn = unsafeBitCast(method_getImplementation(method), to: InitFn.self)
        var error: NSObject?
        let resourcePath = resourceAssetPath(for: voice)

        let voicePath = voice.path.appendingPathComponent("AssetData", isDirectory: true)

        debug(
            debugEnabled,
            "engine init voicePath=\(voicePath.path) "
            + "resourcePath=\(resourcePath?.path ?? "<nil>")"
        )

        let engine = fn(
            raw,
            sel,
            voicePath.path as NSString,
            resourcePath?.path as NSString?,
            &error
        )

        if let error = error as? NSError {
            // Keep the returned native object alive even after an init error.
            // The private engine has process-global teardown hazards.
            engines[voice.path] = engine
            throw SiriSayError.engineInitialization(voice.specifier, error)
        }

        if voice.kind == "neuralAX" {
            debug(debugEnabled, "skipping preheat for neuralAX \(voice.specifier)")
        } else {
            let preheatSel = NSSelectorFromString("preheatWithError:")
            if let method = class_getInstanceMethod(type(of: engine), preheatSel) {
                typealias PreheatFn = @convention(c) (
                    AnyObject,
                    Selector,
                    UnsafeMutablePointer<AnyObject?>
                ) -> Bool

                let preheat = unsafeBitCast(
                    method_getImplementation(method),
                    to: PreheatFn.self
                )

                var preheatError: AnyObject?
                _ = preheat(engine, preheatSel, &preheatError)

                if let preheatError = preheatError as? NSError {
                    engines[voice.path] = engine
                    throw SiriSayError.preheat(voice.specifier, preheatError)
                }
            }
        }

        engines[voice.path] = engine
        return engine
    }
}

func synthesize(
    text: String,
    voice: Voice,
    rate: Double,
    debugEnabled: Bool,
    pool: EnginePool
) throws -> Data {
    let engine = try pool.engine(for: voice, debugEnabled: debugEnabled)

    let request0 = alloc("SiriTTSSynthesisEngineRequest")
    guard let request = request0.perform(NSSelectorFromString("init"))?
        .takeUnretainedValue() as? NSObject
    else {
        die("could not initialize synthesis request")
    }

    request.setValuesForKeys([
        "text": text,
        "privacySensitive": false,
        "requestId": UUID().uuidString,
        "rate": rate,
        "pitch": 1.0,
        "volume": 1.0,
    ])

    var pcm = Data()

    let audioHandler: AudioHandler = { chunk in
        pcm.append(chunk as Data)
    }
    let wordHandler: WordHandler = { _ in }

    request.perform(NSSelectorFromString("setAudioHandler:"), with: audioHandler)
    request.perform(NSSelectorFromString("setWordTimingsHandler:"), with: wordHandler)

    // Tahoe's _unlockedSynthesize:error: unconditionally invokes this block
    // on the Hydra/dynamic-prompt path. If it is nil, SiriTTSService itself
    // dereferences nil+0x10 and crashes.
    let dynamicPromptHandler: DynamicPromptHandler = { voice, style in
        if debugEnabled {
            let v = voice.map(String.init) ?? "<nil>"
            let s = style.map(String.init) ?? "<nil>"
            fputs("siri-say: dynamic prompt voice=\(v) style=\(s)\n", stderr)
        }
    }

    request.perform(
        NSSelectorFromString("setDynamicPromptHandler:"),
        with: dynamicPromptHandler
    )

    let issueHandler: IssueHandler = { issue in
        guard debugEnabled else { return }

        let description: String
        if let object = issue as AnyObject? {
            description = String(describing: object)
        } else {
            description = "<nil>"
        }

        FileHandle.standardError.write(
            Data(("siri-say: synthesis issue: \(description)\n").utf8)
        )
    }
    request.perform(
        NSSelectorFromString("setSynthesisIssueHandler:"),
        with: issueHandler
    )

    let sel = NSSelectorFromString("synthesize:error:")
    guard let method = class_getInstanceMethod(type(of: engine), sel) else {
        die("synthesize:error: unavailable")
    }

    typealias SynthFn = @convention(c) (
        AnyObject,
        Selector,
        AnyObject,
        UnsafeMutablePointer<NSObject?>?
    ) -> Bool

    let fn = unsafeBitCast(method_getImplementation(method), to: SynthFn.self)
    var error: NSObject?
    let ok = fn(engine, sel, request, &error)

    if let error = error as? NSError {
        throw SiriSayError.synthesis(voice.specifier, error)
    }
    guard ok, !pcm.isEmpty else {
        throw SiriSayError.noAudio(voice.specifier)
    }

    return pcm
}

struct Segment {
    let text: String
    let language: String
}

private struct DetectedSegmentDraft {
    let text: String
    let sentence: String
    let detectedLanguage: String
    let paragraphBreakBefore: Bool
}

private func hasParagraphBreak(_ gap: String) -> Bool {
    gap.range(of: #"\n[ \t\r]*\n"#, options: .regularExpression) != nil
}

private func isChineseTag(_ language: String) -> Bool {
    baseLanguage(language.lowercased()) == "zh"
        || chineseVariant(forConcreteLanguage: language) != nil
}

private enum ChineseScript {
    case hans
    case hant
}

private func chineseScript(_ language: String) -> ChineseScript? {
    switch language.lowercased() {
    case "zh-hans": return .hans
    case "zh-hant": return .hant
    default: return nil
    }
}

private func nearbyChineseContext(
    for index: Int,
    drafts: [DetectedSegmentDraft],
    direct: [ChineseDirectResolution?]
) -> (variant: ChineseSpokenVariant, reason: String)? {
    let targetScript = chineseScript(drafts[index].detectedLanguage)

    var previous: (ChineseSpokenVariant, Int)?
    var j = index - 1
    while j >= 0 {
        // drafts[j + 1].paragraphBreakBefore is the boundary between j and j+1.
        if drafts[j + 1].paragraphBreakBefore { break }
        if !isChineseTag(drafts[j].detectedLanguage) { break }
        if let targetScript,
           let candidateScript = chineseScript(drafts[j].detectedLanguage),
           candidateScript != targetScript {
            break
        }
        if let resolution = direct[j] {
            previous = (resolution.variant, index - j)
            break
        }
        j -= 1
    }

    var next: (ChineseSpokenVariant, Int)?
    j = index + 1
    while j < drafts.count {
        if drafts[j].paragraphBreakBefore { break }
        if !isChineseTag(drafts[j].detectedLanguage) { break }
        if let targetScript,
           let candidateScript = chineseScript(drafts[j].detectedLanguage),
           candidateScript != targetScript {
            break
        }
        if let resolution = direct[j] {
            next = (resolution.variant, j - index)
            break
        }
        j += 1
    }

    switch (previous, next) {
    case let ((pv, pd)?, (nv, nd)?) where pv == nv:
        return (pv, "local Chinese context: both sides \(pv.rawValue), distances \(pd)/\(nd)")
    case let ((pv, pd)?, nil):
        return (pv, "local Chinese context: previous \(pv.rawValue), distance \(pd)")
    case let (nil, (nv, nd)?):
        return (nv, "local Chinese context: next \(nv.rawValue), distance \(nd)")
    case let ((pv, _)?, (nv, _)?) where pv != nv:
        // We are near an actual variety switch; do not smear either voice over
        // the ambiguous sentence.
        return nil
    default:
        return nil
    }
}

func detectedSegments(_ text: String, debugEnabled: Bool = false) -> [Segment] {
    let installedLanguages = Array(Set(voices.map(\.language)))
    func detect(_ text: String) -> String? {
        detectAvailableLanguage(
            text, installedLanguages: installedLanguages,
            fallbackLanguage: currentSiriSettings?.language,
            debugEnabled: debugEnabled
        )
    }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text

    var drafts: [DetectedSegmentDraft] = []
    var cursor = text.startIndex

    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) {
        sentenceRange, _ in

        let gap = String(text[cursor..<sentenceRange.lowerBound])
        let outputRange = cursor..<sentenceRange.upperBound
        let sentence = String(text[sentenceRange])

        if let language = detect(sentence) {
            drafts.append(
                DetectedSegmentDraft(
                    text: String(text[outputRange]),
                    sentence: sentence,
                    detectedLanguage: language,
                    paragraphBreakBefore: hasParagraphBreak(gap)
                )
            )
        } else if let previous = drafts.last {
            // Punctuation/numbers-only sentence: preserve the previous detected
            // language. Voice routing happens in the second pass below.
            drafts.append(
                DetectedSegmentDraft(
                    text: String(text[outputRange]),
                    sentence: sentence,
                    detectedLanguage: previous.detectedLanguage,
                    paragraphBreakBefore: hasParagraphBreak(gap)
                )
            )
        }

        cursor = sentenceRange.upperBound
        return true
    }

    if cursor < text.endIndex {
        let tail = String(text[cursor..<text.endIndex])
        if let last = drafts.indices.last {
            let old = drafts[last]
            drafts[last] = DetectedSegmentDraft(
                text: old.text + tail,
                sentence: old.sentence,
                detectedLanguage: old.detectedLanguage,
                paragraphBreakBefore: old.paragraphBreakBefore
            )
        } else if let language = detect(text) {
            drafts.append(
                DetectedSegmentDraft(
                    text: text,
                    sentence: text,
                    detectedLanguage: language,
                    paragraphBreakBefore: false
                )
            )
        }
    }

    if drafts.isEmpty,
       let language = detect(text) {
        drafts.append(
            DetectedSegmentDraft(
                text: text,
                sentence: text,
                detectedLanguage: language,
                paragraphBreakBefore: false
            )
        )
    }

    // First pass: resolve only Chinese segments whose own text supplies a
    // concrete locale or strong CanCLID Cantonese/SWC evidence. This gives us
    // anchors for discourse continuity without letting a global preference
    // contaminate the context.
    let direct: [ChineseDirectResolution?] = drafts.map { draft in
        guard isChineseTag(draft.detectedLanguage) else { return nil }
        return directChineseResolution(
            text: draft.sentence,
            detectedLanguage: draft.detectedLanguage
        )
    }

    return drafts.enumerated().map { index, draft in
        guard isChineseTag(draft.detectedLanguage) else {
            return Segment(text: draft.text, language: draft.detectedLanguage)
        }

        if let resolution = direct[index] {
            let resolved = language(for: resolution.variant)
            debug(
                debugEnabled,
                "Chinese routing \(draft.detectedLanguage) -> \(resolved) "
                + "[\(resolution.reason)]"
            )
            return Segment(text: draft.text, language: resolved)
        }

        if let context = nearbyChineseContext(
            for: index,
            drafts: drafts,
            direct: direct
        ) {
            let resolved = language(for: context.variant)
            debug(
                debugEnabled,
                "Chinese routing \(draft.detectedLanguage) -> \(resolved) "
                + "[\(context.reason)]"
            )
            return Segment(text: draft.text, language: resolved)
        }

        let fallback = fallbackChineseResolution(
            detectedLanguage: draft.detectedLanguage
        )
        let resolved = language(for: fallback.variant)
        debug(
            debugEnabled,
            "Chinese routing \(draft.detectedLanguage) -> \(resolved) "
            + "[\(fallback.reason)]"
        )
        return Segment(text: draft.text, language: resolved)
    }
}

func le<T: FixedWidthInteger>(_ value: T) -> Data {
    var x = value.littleEndian
    return withUnsafeBytes(of: &x) { Data($0) }
}

// SiriTTS currently receives 48 kHz, mono, signed 16-bit PCM.
func wav(_ pcm: Data) -> Data {
    let channels: UInt16 = 1
    let sampleRate: UInt32 = 48_000
    let bits: UInt16 = 16

    let byteRate = sampleRate * UInt32(channels) * UInt32(bits) / 8
    let blockAlign = channels * bits / 8
    let dataSize = UInt32(pcm.count)

    var data = Data()
    data.append(Data("RIFF".utf8))
    data.append(le(UInt32(36) + dataSize))
    data.append(Data("WAVE".utf8))

    data.append(Data("fmt ".utf8))
    data.append(le(UInt32(16)))
    data.append(le(UInt16(1)))
    data.append(le(channels))
    data.append(le(sampleRate))
    data.append(le(byteRate))
    data.append(le(blockAlign))
    data.append(le(bits))

    data.append(Data("data".utf8))
    data.append(le(dataSize))
    data.append(pcm)
    return data
}

