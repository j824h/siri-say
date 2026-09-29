let version = "0.1.0"

let usage = """
Usage: siri-say [options] [text ...]

Speak with installed Siri voices. Reads UTF-8 stdin when text is omitted.
Piped input defaults to paragraph mode: blank or whitespace-only lines end a
chunk; internal newlines become spaces. EOF submits the final chunk.
This is blank-line grouping, not Apple's NLP paragraph tokenization.
At a terminal, speaks each line after Enter; Ctrl-D ends input.
Detects each sentence's language unless -l or a qualified -v specifies one.
Playback runs while upcoming audio is generated.
Ctrl-C stops generation and finishes queued audio; then Ctrl-C stops playback,
or Ctrl-D returns to the shell while queued audio finishes (requires a terminal).

Options:
  -l, --language TAG  Choose a language; otherwise detect each sentence
  -v, --voice VOICE   Choose a voice in the selected or detected language
  -v LANGUAGE:VOICE   Choose both language and voice
  -v LANGUAGE:        Choose a language and its preferred voice (like -l)
  -v '?'              List installed voices (--list also works)
  -o FILE             Save a 48 kHz, mono, 16-bit WAV instead of playing
  --stream MODE       Input chunks: paragraph (default) or line; terminal uses line
  --rate NUMBER       Positive Siri engine rate multiplier (default: 1.0)
  --kind KIND         Filter voice implementation (for example, natural)
  --debug             Print voice selection and synthesis diagnostics
  -h, --help          Show this help
  --version           Show version
  --                  Treat remaining arguments as text

Examples:
  siri-say "Hello!"
  siri-say -l en-US -o hello.wav "Hello!"
  echo "Hello! 안녕하세요!" | siri-say

Requires macOS 26 or later and downloaded Siri voices. Uses private Apple APIs.
"""
