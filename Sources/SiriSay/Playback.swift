import Foundation
import AVFoundation
import Darwin

// Workers are implementation modes of the same installed executable. Only the
// supervisor handles terminal signals; each worker watches for parent death.
func configureSpeechWorker() -> DispatchSourceTimer {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_DFL)
    signal(SIGHUP, SIG_DFL)
    let parent = getppid()
    guard parent != 1 else { Darwin._exit(1) }
    // Foundation may create a new process group. Terminal input must remain in
    // the supervisor's foreground group or reads would stop with SIGTTIN.
    _ = setpgid(0, getpgid(parent))
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler {
        if getppid() != parent { Darwin._exit(1) }
    }
    timer.resume()
    return timer
}

func runPlaybackWorker() -> Never {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_DFL)
    signal(SIGHUP, SIG_DFL)
    signal(SIGUSR1, SIG_IGN)
    let parent = getppid()
    guard parent != 1 else { Darwin._exit(1) }
    let control = DispatchQueue(label: "siri-say.player-control")
    var detached = false
    let detach = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: control)
    detach.setEventHandler {
        detached = true
        // Acknowledge before the supervisor exits, avoiding a parent-death race.
        try? FileHandle.standardOutput.write(contentsOf: Data("detached\n".utf8))
    }
    detach.resume()
    let watchdog = DispatchSource.makeTimerSource(queue: control)
    watchdog.schedule(deadline: .now(), repeating: .milliseconds(100))
    watchdog.setEventHandler {
        if !detached && getppid() != parent { Darwin._exit(1) }
    }
    watchdog.resume()

    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    // Fifty 100 ms buffers: bounded lookahead, continuous scheduling rather than
    // starting a separate player for every sentence. Pipe capacity is also bounded.
    let slots = DispatchSemaphore(value: 50)
    let completed = DispatchGroup()
    var started = false
    var trailingByte: UInt8?
    do {
        while true {
            slots.wait()
            var bytes = [UInt8](repeating: 0, count: 9_600)
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 {
                slots.signal()
                if errno == EINTR { continue }
                die("reading playback audio: \(String(cString: strerror(errno)))")
            }
            if count == 0 {
                guard trailingByte == nil else { die("incomplete playback sample") }
                slots.signal()
                break
            }
            // Submit short reads immediately: waiting to fill a 100 ms block
            // would withhold the end of an interactive line until more input.
            var pcm = Data()
            if let byte = trailingByte { pcm.append(byte) }
            pcm.append(contentsOf: bytes.prefix(count))
            trailingByte = pcm.count % 2 == 0 ? nil : pcm.removeLast()
            if pcm.isEmpty { slots.signal(); continue }
            if engine == nil {
                let newEngine = AVAudioEngine()
                let newPlayer = AVAudioPlayerNode()
                newEngine.attach(newPlayer)
                newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
                engine = newEngine
                player = newPlayer
            }
            let frames = AVAudioFrameCount(pcm.count / 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let samples = buffer.floatChannelData![0]
            pcm.withUnsafeBytes { bytes in
                for i in 0..<Int(frames) {
                    let value = UInt16(bytes[i * 2]) | (UInt16(bytes[i * 2 + 1]) << 8)
                    samples[i] = Float(Int16(bitPattern: value)) / 32768
                }
            }
            completed.enter()
            player!.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                slots.signal()
                completed.leave()
            }
            if !started {
                try engine!.start()
                player!.play()
                started = true
                try FileHandle.standardOutput.write(contentsOf: Data("playing\n".utf8))
            }
        }
        // Only offer cancellation choices when EOF leaves audio to finish.
        // An idle worker can still be alive while waiting for more input.
        if completed.wait(timeout: .now()) == .timedOut {
            try FileHandle.standardOutput.write(contentsOf: Data("draining\n".utf8))
            completed.wait()
            try FileHandle.standardOutput.write(contentsOf: Data("drained\n".utf8))
        }
        player?.stop()
        engine?.stop()
        Darwin._exit(0)
    } catch {
        die("playback: \(error)")
    }
}

// All mutable supervisor state is confined to this serial queue. Synthesis runs
// in a worker so cancellation does not depend on private Siri API cooperation.
final class SpeechPipeline {
    let queue = DispatchQueue(label: "siri-say.supervisor")
    let generator = Process()
    let player = Process()
    let audio = Pipe()
    let events = Pipe()
    var sources: [DispatchSourceSignal] = []
    var timer: DispatchSourceTimer?
    var terminal: Int32 = -1
    var cancelled = false
    var detaching = false
    var draining = false
    var prompted = false
    var generatorStatus: Int32?
    var playerStatus: Int32?
    var eventBuffer = Data()
    let debugEnabled: Bool

    init(debugEnabled: Bool) { self.debugEnabled = debugEnabled }

    // Workers own no persistent output. Direct termination also works during
    // startup, before exec/worker entry resets inherited signal dispositions.
    func finish(_ status: Int32, leavePlayer: Bool = false) -> Never {
        if terminal >= 0 { close(terminal) }
        if generator.isRunning { kill(generator.processIdentifier, SIGKILL); generator.waitUntilExit() }
        if !leavePlayer && player.isRunning { kill(player.processIdentifier, SIGKILL); player.waitUntilExit() }
        Darwin._exit(status)
    }

    func interrupt() {
        if cancelled { finish(130) }
        cancelled = true
        if generator.isRunning { kill(generator.processIdentifier, SIGKILL) }
        terminal = open("/dev/tty", O_RDWR | O_NONBLOCK)
        guard terminal >= 0, tcgetpgrp(terminal) == getpgrp() else { finish(130) }
    }

    func poll() {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = read(events.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            eventBuffer.append(contentsOf: bytes.prefix(count))
            while let end = eventBuffer.firstIndex(of: 10) {
                let event = String(decoding: eventBuffer[..<end], as: UTF8.self)
                eventBuffer.removeSubrange(...end)
                if event == "playing" { debug(debugEnabled, "playback started; synthesis continues ahead") }
                if event == "draining" { draining = true }
                if event == "drained" { draining = false }
                if event == "detached", detaching {
                    fputs("siri-say: playback continues as PID \(player.processIdentifier) (kill \(player.processIdentifier) to stop)\n", stderr)
                    finish(130, leavePlayer: true)
                }
            }
        }
        if cancelled && draining && !prompted && player.isRunning {
            prompted = true
            let message = "\n^C: stop audio and exit · ^D: leave audio playing and exit\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }
        if cancelled && !detaching && terminal >= 0 {
            // Leave terminal settings unchanged. Canonical Ctrl-D on an empty
            // line makes read return zero; O_NONBLOCK yields EAGAIN while idle.
            let n = read(terminal, &bytes, bytes.count)
            if n == 0 || (n > 0 && bytes.prefix(n).contains(4)) {
                if !player.isRunning { finish(130) }
                detaching = true
                kill(player.processIdentifier, SIGUSR1)
            }
        }
        if let status = playerStatus {
            if cancelled { finish(130) }
            if status != 0 { finish(status) }
            if let generation = generatorStatus { finish(generation) }
        }
        if let status = generatorStatus, status != 0 && !cancelled { finish(status) }
    }

    func run(arguments: [String]) -> Never {
        // Children inherit ignored SIGINT until they install their own handlers.
        // This also protects the short interval between spawn and worker entry.
        signal(SIGUSR1, SIG_IGN)
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [self] in
                if sig == SIGINT {
                    if source.data > 1 { finish(130) }
                    interrupt()
                } else {
                    finish(128 + sig)
                }
            }
            source.resume()
            sources.append(source)
        }
        let executable = Bundle.main.executableURL!
        player.executableURL = executable
        player.arguments = ["--internal-player"]
        player.standardInput = audio.fileHandleForReading
        player.standardOutput = events.fileHandleForWriting
        player.standardError = FileHandle.standardError
        generator.executableURL = executable
        generator.arguments = ["--internal-synthesis"] + arguments
        generator.standardInput = FileHandle.standardInput
        generator.standardOutput = audio.fileHandleForWriting
        generator.standardError = FileHandle.standardError
        player.terminationHandler = { [self] process in
            queue.async { self.playerStatus = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus }
        }
        generator.terminationHandler = { [self] process in
            queue.async { self.generatorStatus = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus }
        }
        queue.async { [self] in
            do {
                try player.run()
                try generator.run()
                try audio.fileHandleForReading.close()
                try audio.fileHandleForWriting.close()
                try events.fileHandleForWriting.close()
                let fd = events.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(10))
                timer.setEventHandler { [self] in poll() }
                timer.resume()
                self.timer = timer
            } catch {
                fputs("siri-say: starting audio pipeline: \(error)\n", stderr)
                finish(1)
            }
        }
        dispatchMain()
    }
}
