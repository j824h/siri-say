let version = "0.1.0"

let usage = """
Usage: siri-say [options] [text ...]

Speak with installed Siri voices. Reads UTF-8 stdin when text is omitted.
At a terminal, speaks each line after Enter; Ctrl-D ends input.
Detects each sentence's language unless -v specifies one.

Options:
  -v LANGUAGE[:VOICE]  Choose a language and optional voice from the list
  -v '?'              List installed voices (--list also works)
  -o FILE             Save a 48 kHz, mono, 16-bit WAV instead of playing
  --rate NUMBER       Positive Siri engine rate multiplier (default: 1.0)
  --kind KIND         Filter voice implementation (for example, natural)
  --debug             Print voice selection and synthesis diagnostics
  -h, --help          Show this help
  --version           Show version
  --                  Treat remaining arguments as text

Examples:
  siri-say "Hello!"
  siri-say -v en-US -o hello.wav "Hello!"
  echo "Hello! 안녕하세요!" | siri-say

Requires macOS 26 or later and downloaded Siri voices. Uses private Apple APIs.
"""
