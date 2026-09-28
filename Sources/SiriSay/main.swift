import Foundation
import Darwin


var requestedLanguage: String?
var voiceLanguage: String?
var fixedVoiceName: String?
var fixedVoiceKind: String?
var outputPath: String?
var rawRate = 1.0
var debugEnabled = false
var textParts: [String] = []
var listVoices = false

var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]

    switch arg {
    case "-h", "--help":
        print(usage)
        exit(0)

    case "--version":
        print("siri-say \(version)")
        exit(0)

    case "-l", "--language":
        i += 1
        guard i < CommandLine.arguments.count else {
            die("\(arg) requires a language tag")
        }
        let value = CommandLine.arguments[i]
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains(":"), !value.hasPrefix("-") else {
            die("\(arg) requires a language tag")
        }
        requestedLanguage = value

    case "-v", "--voice":
        i += 1
        guard i < CommandLine.arguments.count else {
            die("\(arg) requires a voice, LANGUAGE:VOICE, LANGUAGE:, or '?'")
        }

        let value = CommandLine.arguments[i]
        if value == "?" {
            listVoices = true
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= 2,
                  parts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  !value.hasPrefix("-") else {
                die("\(arg) requires a voice, LANGUAGE:VOICE, LANGUAGE:, or '?'")
            }
            voiceLanguage = parts.count == 2 && !parts[0].isEmpty ? parts[0] : nil
            let name = parts.last!
            fixedVoiceName = name.isEmpty ? nil : name
        }

    case "--list":
        // Backward-compatible alias from the prototype. Prefer: -v '?'
        listVoices = true

    case "--debug":
        debugEnabled = true

    case "--kind":
        i += 1
        guard i < CommandLine.arguments.count else {
            die("--kind requires a voice kind")
        }
        fixedVoiceKind = CommandLine.arguments[i]

    case "--rate":
        i += 1
        guard i < CommandLine.arguments.count,
              let rate = Double(CommandLine.arguments[i]), rate.isFinite, rate > 0
        else {
            die("--rate requires a finite, positive Siri engine rate")
        }
        rawRate = rate

    case "-o":
        i += 1
        guard i < CommandLine.arguments.count else {
            die("-o requires a filename")
        }
        outputPath = CommandLine.arguments[i]

    case "--":
        textParts.append(contentsOf: CommandLine.arguments[(i + 1)...])
        i = CommandLine.arguments.count
        continue

    default:
        if arg.hasPrefix("-") {
            die("unknown option \(arg)")
        }
        textParts.append(arg)
    }

    i += 1
}

if let requestedLanguage, let voiceLanguage,
   requestedLanguage.caseInsensitiveCompare(voiceLanguage) != .orderedSame {
    die("conflicting languages: -l \(requestedLanguage) and -v \(voiceLanguage):")
}
let fixedVoiceLanguage = voiceLanguage ?? requestedLanguage

if listVoices {
    loadFrameworks()
    _ = setlocale(LC_CTYPE, "")

    struct VoiceRow {
        let id: String
        let systemLabel: String
        let name: String
        let kind: String
    }

    let rows = voices.map { voice in
        VoiceRow(
            id: "\(voice.language):\(voice.name)",
            systemLabel: pickerLabel(for: voice) ?? "-",
            name: friendlyVoiceName(voice.name),
            kind: "\(voice.kind).\(voice.footprint)"
        )
    }

    let headers = VoiceRow(
        id: "ID",
        systemLabel: "System Settings",
        name: "Name",
        kind: "Kind"
    )

    let idWidth = ([headers.id] + rows.map(\.id)).map(terminalCellWidth).max() ?? 0
    let labelWidth = ([headers.systemLabel] + rows.map(\.systemLabel)).map(terminalCellWidth).max() ?? 0
    let nameWidth = ([headers.name] + rows.map(\.name)).map(terminalCellWidth).max() ?? 0

    func printRow(_ row: VoiceRow) {
        print(
            paddedForTerminal(row.id, to: idWidth) + "  "
            + paddedForTerminal(row.systemLabel, to: labelWidth) + "  "
            + paddedForTerminal(row.name, to: nameWidth) + "  "
            + row.kind
        )
    }

    printRow(headers)
    for row in rows {
        printRow(row)
    }
    exit(0)
}

// Retain engines across interactive lines; private engine teardown is unsafe.
let pool = EnginePool()
var frameworksLoaded = false

func speak(_ inputText: String) -> Int32 {
    if !frameworksLoaded {
        loadFrameworks()
        frameworksLoaded = true
    }
    let segments: [Segment]

    if let fixedVoiceLanguage {
        segments = [
            Segment(
                text: inputText,
                language: resolvedChineseLanguage(
                    text: inputText,
                    detectedLanguage: fixedVoiceLanguage,
                    debugEnabled: debugEnabled
                )
            )
        ]
    } else {
        segments = detectedSegments(inputText, debugEnabled: debugEnabled)
        guard !segments.isEmpty else {
            die("could not detect input language; specify one with -l")
        }
    }

    var allPCM = Data()

    for segment in segments {
        let candidates = candidateVoices(
            language: segment.language,
            requestedName: fixedVoiceName,
            requestedKind: fixedVoiceKind,
            allowCurrentSiriBaseLanguage: fixedVoiceLanguage == nil,
            debugEnabled: debugEnabled
        )

        guard !candidates.isEmpty else {
            die(
                "no installed Siri voice matching \(segment.language)"
                + (fixedVoiceName.map { ":\($0)" } ?? "")
            )
        }

        var segmentPCM: Data?
        var failures: [String] = []

        for voice in candidates {
            debug(
                debugEnabled,
                "trying \(segment.language) -> \(voice.specifier) "
                + "[\(segment.text.debugDescription)]"
            )

            do {
                let pcm = try synthesize(
                    text: segment.text,
                    voice: voice,
                    rate: rawRate,
                    debugEnabled: debugEnabled,
                    pool: pool
                )
                segmentPCM = pcm
                debug(debugEnabled, "selected \(voice.specifier)")
                break
            } catch {
                failures.append(String(describing: error))
                debug(debugEnabled, "rejected \(voice.specifier): \(error)")
            }
        }

        guard let segmentPCM else {
            let detail = failures.map { "  \($0)" }.joined(separator: "\n")
            die(
                "all matching Siri voices failed for \(segment.language)"
                + (detail.isEmpty ? "" : "\n\(detail)")
            )
        }

        allPCM.append(segmentPCM)
    }

    let audio = wav(allPCM)

    if let outputPath {
        do {
            try audio.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            die("writing \(outputPath): \(error)")
        }

        return 0
    }

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("siri-say-\(UUID().uuidString).wav")

    do {
        try audio.write(to: tmp)
    } catch {
        die("writing temporary WAV: \(error)")
    }

    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [tmp.path]

    do {
        try player.run()
        player.waitUntilExit()
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        die("afplay: \(error)")
    }

    try? FileManager.default.removeItem(at: tmp)

    return player.terminationStatus
}

if textParts.isEmpty && isatty(STDIN_FILENO) != 0 {
    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        let status = speak(line)
        if status != 0 { Darwin._exit(status) }
    }
    Darwin._exit(0)
}

let inputText: String
if textParts.isEmpty {
    guard let text = String(
        data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8
    ) else {
        die("stdin must be UTF-8 text")
    }
    inputText = text
} else {
    inputText = textParts.joined(separator: " ")
}

guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    die("no text")
}

// Deliberately skip native engine teardown, including on interactive EOF.
Darwin._exit(speak(inputText))
