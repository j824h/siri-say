# siri-say

Speak text using the Siri voices installed on your Mac. Automatically switches
voices between sentences in different languages, or lets you choose a voice.
Play the result aloud or save it as a WAV file.

```sh
siri-say "Hello! 안녕하세요!"
echo "Read this aloud." | siri-say
siri-say -l en-US -o hello.wav "Hello!"
```

## Requirements

- macOS 26 or later. This is an experimental tool using private Apple frameworks;
  OS updates can change compatibility. The deployment target is 26, but each OS
  version needs a real synthesis check before claiming support.
- Downloaded Siri voice assets. Choose a Siri language and voice in System
  Settings and allow its download to complete. Run `siri-say -v '?'` to see what
  the tool finds locally.
- To build: Xcode Command Line Tools with Swift 5.9 or later and a macOS 26+
  SDK. Install Apple's tools with `xcode-select --install` if needed.

Apple Silicon is the initial verification target. Intel synthesis is unverified.
The package has no third-party Swift dependencies and does not bundle Apple voices.
Locally verified on Apple Silicon with macOS 27.0 and Swift 6.4: release build,
CLI checks, installation, voice listing, and English/Korean WAV synthesis.
macOS 26 synthesis remains to be verified.

## Install from source

Clone [j824h/siri-say](https://github.com/j824h/siri-say), then run:

```sh
git clone https://github.com/j824h/siri-say.git
cd siri-say
sh scripts/install.sh
```

This builds an optimized executable and installs it at `~/.local/bin/siri-say`.
If that directory is not on your PATH, add this to `~/.zshrc` and open a new shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Choose another installation prefix with `PREFIX=/your/prefix sh scripts/install.sh`.
Update by fetching a new release and running the installer again. Uninstall with
`rm ~/.local/bin/siri-say` (adjust the path for a custom prefix).

You can also run directly from the checkout:

```sh
sh scripts/build.sh
.build/standalone/release/siri-say --help
```

## Usage

```text
siri-say [options] [text ...]
```

| Option | Meaning |
| --- | --- |
| `-l TAG`, `--language TAG` | Choose a language instead of detecting it |
| `-v VOICE`, `--voice VOICE` | Choose a voice in the selected or detected language |
| `-v LANGUAGE:VOICE` | Choose both language and voice |
| `-v LANGUAGE:` | Choose a language and its preferred voice, like `-l LANGUAGE` |
| `-v '?'`, `--list` | List installed voice IDs, System Settings labels, and kinds |
| `-o FILE` | Write WAV instead of playing audio |
| `--stream paragraph`, `--stream line` | Speak at blank lines or each newline; terminal input always uses line mode |
| `--rate NUMBER` | Positive engine rate multiplier; default `1.0` |
| `--kind KIND` | Select an implementation such as `natural`, `neural`, or `neuralAX` |
| `--debug` | Show routing, asset, and synthesis diagnostics on stderr |
| `-h`, `--help` | Show help |
| `--version` | Show version |
| `--` | Treat the remaining arguments as text, including leading dashes |

Use a System Settings label (`-v 'Voice 2'`), or a qualified label
(`-v 'en-US:Voice 2'`). IDs from the list (`-v en-US:simone`) also work.
Select only a language with `-l en-US` or `-v 'en-US:'`. A bare value after `-v`
is always a voice name, so the old `-v en-US` spelling is now `-l en-US`.
Without a language selection, `-v 'Voice 2'` selects Voice 2 for each detected
sentence language; a missing matching voice reports an error.
`-l en-US -v 'Voice 2'` is equivalent to `-v 'en-US:Voice 2'`.
Conflicting languages in `-l` and qualified `-v` report an error in either order.
Quote voice names containing spaces. Quote `'?'` so your shell does not expand it.
With no text arguments, the tool reads UTF-8 stdin. At a terminal it speaks each
line after Enter and continues until Ctrl-D. Piped input defaults to paragraph
mode. Here, **paragraph means a block of nonblank lines separated by one or more
blank or whitespace-only lines**. EOF submits the final block, even without a
trailing newline. Input lines use LF or CRLF endings.

This is a plain-text grouping convention. It does not use Apple's
[`NLTokenizer(unit: .paragraph)`](https://developer.apple.com/documentation/naturallanguage/nltokenunit/paragraph),
whose documented example treats a single newline as a paragraph boundary.
A Unicode paragraph separator (U+2029) within a line is not a streaming boundary.

Use `--stream line` to speak each completed line as it arrives:

```sh
tail -f messages.txt | siri-say --stream line -l en-US
cat document.txt | siri-say --stream paragraph
```

Paragraph mode joins internal newlines with spaces before synthesis, including
when a voice is explicitly selected. Blank chunks and successful synthesis with
no audio are skipped. Empty input exits successfully without creating or
truncating an output file. Language routing uses the context within each chunk.

Synthesis runs ahead while a separate playback worker continuously plays queued
audio. The playback queue holds up to five seconds, plus a small pipe buffer;
when full, it makes synthesis wait. Each synthesis segment is still generated in
memory before being sent to the queue. Slow synthesis can exhaust the queue and
cause a gap, but playback no longer waits between every generation request.
Both workers are modes of the same executable; no additional installation is
needed.

During playback, **Ctrl-C stops input and generation**, then finishes audio
already sent to the playback queue. The terminal offers two choices:

- **Ctrl-C again:** stop playback and exit immediately.
- **Ctrl-D:** return to the shell while the playback worker finishes its queue.
  The printed PID can be stopped with `kill PID`.

The control hint uses `^C` and `^D` and appears only while audio remains to finish;
an empty queue exits without a message.

There is no double-press timeout. These choices also work with piped text when
there is a foreground controlling terminal. Without one, SIGINT stops everything.
SIGTERM and SIGHUP stop both workers. Workers also exit if the supervisor dies
unexpectedly; only explicit detachment permits playback to survive it. A normal
input EOF finishes all submitted text and waits for playback. Interrupted runs
exit with status 130, including when playback is detached. With `-o`, Ctrl-C
interrupts file generation directly; there is no playback to detach.

`-o` accumulates all chunks into one WAV, updating its header as audio is added.
Output files are always 48 kHz, mono, signed 16-bit PCM WAV, regardless of the
filename extension. Existing output files are overwritten when the first audio
is produced.

Automatic selection considers sentence language, your configured Siri voice,
Apple's locale default, and installed implementations. It tries another matching
voice when synthesis reports a failure. Language detection considers ranked
candidates and selects the highest-ranked language with an installed voice.
If none of the candidates is installed, it falls back to your configured Siri
language when available. Explicit language selections are not replaced by this
fallback. Chinese routing uses Cantonese and
Standard Written Chinese features and nearby sentence context; ambiguous text
uses system preferences, then Mandarin. Use `-l zh-HK` or `-l zh-CN` to select
Cantonese or Mandarin explicitly.

## Troubleshooting

- **No installed voice matching a language:** check the voice list and download
  the corresponding Siri voice in System Settings.
- **A voice fails:** use `--debug` to inspect which asset failed; try another ID
  from the list or another `--kind`. Private framework behavior varies by OS.
- **Language detection is wrong:** specify `-l LANGUAGE`. Very short text may
  not provide enough evidence for automatic detection.
- **Sharing diagnostics:** `--debug` includes input text and local asset paths.

## Development and releases

```sh
sh scripts/build.sh
sh scripts/check-language.sh
python3 scripts/check-cli.py .build/standalone/release/siri-say
```

The build script uses `swiftc` directly because the project has no package
dependencies. This avoids nonexistent `Developer/usr/lib` and
`Developer/Library/Frameworks` search paths injected by Swift Build with the
Command Line Tools toolchain, without suppressing linker warnings. `Package.swift`
remains available for SwiftPM and editor integration; raw `swift build` may still
emit those toolchain warnings.

CI runs build, CLI, and installation checks without requiring downloaded voices.
Real synthesis must also be checked on a Mac with voice assets:

```sh
.build/standalone/release/siri-say -v '?'
.build/standalone/release/siri-say -l en-US -o /tmp/siri-say-check.wav "Release check."
afplay /tmp/siri-say-check.wav
python3 scripts/check-interactive.py .build/standalone/release/siri-say
python3 scripts/check-playback.py .build/standalone/release/siri-say
```

Source lives in `Sources/SiriSay`: `main.swift` handles the CLI, `Help.swift`
contains help and version information, `Playback.swift` manages the audio queue
and worker lifecycle, and `Runtime.swift` contains voice
discovery, language routing, synthesis, and WAV encoding. The process deliberately
skips private engine teardown because it can crash or hang.

Create a release archive and checksum with `sh scripts/package.sh`.

## License and credits

Licensed under the [MIT License](LICENSE).
The adapted Cantonese classifier comes from
[CanCLID/cantonesedetect](https://github.com/CanCLID/cantonesedetect), under MIT;
its notice is included in [LICENSES](LICENSES/cantonesedetect-MIT.txt).
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
