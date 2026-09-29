import Foundation
import Darwin


var arguments = CommandLine.arguments
if arguments.dropFirst().first == "--internal-player" { runPlaybackWorker() }
let synthesisWorker = arguments.dropFirst().first == "--internal-synthesis"
var workerWatchdog: DispatchSourceTimer?
if synthesisWorker {
    arguments.remove(at: 1)
    workerWatchdog = configureSpeechWorker()
}

var requestedLanguage: String?
var voiceLanguage: String?
var fixedVoiceName: String?
var fixedVoiceKind: String?
var outputPath: String?
var rawRate = 1.0
var debugEnabled = false
var textParts: [String] = []
var listVoices = false
var streamMode = "paragraph"

var i = 1
while i < arguments.count {
    let arg = arguments[i]

    switch arg {
    case "-h", "--help":
        print(usage)
        exit(0)

    case "--version":
        print("siri-say \(version)")
        exit(0)

    case "-l", "--language":
        i += 1
        guard i < arguments.count else {
            die("\(arg) requires a language tag")
        }
        let value = arguments[i]
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains(":"), !value.hasPrefix("-") else {
            die("\(arg) requires a language tag")
        }
        requestedLanguage = value

    case "-v", "--voice":
        i += 1
        guard i < arguments.count else {
            die("\(arg) requires a voice, LANGUAGE:VOICE, LANGUAGE:, or '?'")
        }

        let value = arguments[i]
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

    case "--stream":
        i += 1
        guard i < arguments.count,
              ["line", "paragraph"].contains(arguments[i]) else {
            die("--stream requires line or paragraph")
        }
        streamMode = arguments[i]

    case "--debug":
        debugEnabled = true

    case "--kind":
        i += 1
        guard i < arguments.count else {
            die("--kind requires a voice kind")
        }
        fixedVoiceKind = arguments[i]

    case "--rate":
        i += 1
        guard i < arguments.count,
              let rate = Double(arguments[i]), rate.isFinite, rate > 0
        else {
            die("--rate requires a finite, positive Siri engine rate")
        }
        rawRate = rate

    case "-o":
        i += 1
        guard i < arguments.count else {
            die("-o requires a filename")
        }
        outputPath = arguments[i]

    case "--":
        textParts.append(contentsOf: arguments[(i + 1)...])
        i = arguments.count
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

if outputPath == nil && !synthesisWorker {
    SpeechPipeline(debugEnabled: debugEnabled).run(arguments: Array(arguments.dropFirst()))
}

// Retain engines across interactive lines; private engine teardown is unsafe.
let pool = EnginePool()
var frameworksLoaded = false
var outputFile: FileHandle?
var outputBytes: UInt64 = 0

func speak(_ inputText: String) -> Int32 {
    guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
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

        let status = emit(segmentPCM)
        if status != 0 { return status }
    }
    return 0
}

func emit(_ pcm: Data) -> Int32 {
    // Successful synthesis can produce no audio (for example, punctuation).
    guard !pcm.isEmpty else { return 0 }
    if let outputPath {
        do {
            guard outputBytes + UInt64(pcm.count) <= UInt64(UInt32.max) - 36 else {
                die("WAV output exceeds the 4 GiB RIFF limit")
            }
            if outputFile == nil {
                try wav(Data()).write(to: URL(fileURLWithPath: outputPath))
                outputFile = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
            }
            let file = outputFile!
            try file.seekToEnd()
            try file.write(contentsOf: pcm)
            outputBytes += UInt64(pcm.count)
            try file.seek(toOffset: 4)
            try file.write(contentsOf: le(UInt32(outputBytes) + 36))
            try file.seek(toOffset: 40)
            try file.write(contentsOf: le(UInt32(outputBytes)))
        } catch {
            die("writing \(outputPath): \(error)")
        }
        return 0
    }
    do {
        try FileHandle.standardOutput.write(contentsOf: pcm)
        debug(debugEnabled, "queued \(pcm.count) PCM bytes")
    } catch {
        die("sending audio to player: \(error)")
    }
    return 0
}

func consumeLine(_ line: String, mode: String, paragraph: inout [String]) {
    if mode == "line" {
        let status = speak(line)
        if status != 0 { Darwin._exit(status) }
    } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let status = speak(paragraph.joined(separator: " "))
        paragraph.removeAll(keepingCapacity: true)
        if status != 0 { Darwin._exit(status) }
    } else {
        paragraph.append(line)
    }
}

if textParts.isEmpty {
    let mode = isatty(STDIN_FILENO) != 0 ? "line" : streamMode
    var paragraph: [String] = []
    // getline returns each completed line without waiting for pipe EOF. Decode
    // strictly after reading the entire line, including split UTF-8 sequences.
    var buffer: UnsafeMutablePointer<CChar>?
    var capacity = 0
    while true {
        let count = getline(&buffer, &capacity, stdin)
        if count < 0 {
            if ferror(stdin) != 0 { die("reading stdin: \(String(cString: strerror(errno)))") }
            break
        }
        guard var line = String(data: Data(bytes: buffer!, count: count), encoding: .utf8) else {
            die("stdin must be UTF-8 text")
        }
        if line.hasSuffix("\n") { line.removeLast() }
        if line.hasSuffix("\r") { line.removeLast() }
        consumeLine(line, mode: mode, paragraph: &paragraph)
    }
    free(buffer)
    let status = speak(paragraph.joined(separator: " "))
    if status != 0 { Darwin._exit(status) }
} else {
    var paragraph: [String] = []
    for line in textParts.joined(separator: " ").components(separatedBy: "\n") {
        consumeLine(line, mode: streamMode, paragraph: &paragraph)
    }
    let status = speak(paragraph.joined(separator: " "))
    if status != 0 { Darwin._exit(status) }
}
do {
    try outputFile?.close()
} catch {
    die("closing output: \(error)")
}
// Deliberately skip native engine teardown, including on interactive EOF.
Darwin._exit(0)
