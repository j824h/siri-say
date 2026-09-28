#!/usr/bin/env python3
"""Exercise the CLI contract without downloaded voices or audio playback."""
import subprocess
import sys
import os
import pty

binary = sys.argv[1]


def check(args, status, expected, data=b""):
    result = subprocess.run(
        [binary, *args], input=data, capture_output=True, timeout=10
    )
    assert result.returncode == status, (args, result.returncode, result.stderr)
    output = result.stdout if status == 0 else result.stderr
    assert expected.encode() in output, (args, output)


check(["--help"], 0, "Usage: siri-say")
check(["--version"], 0, "siri-say 0.1.0")
check(["--unknown"], 1, "unknown option")
for voice in ("", ":", ":name", "en-US:"):
    check(["-v", voice], 1, "-v requires")
for rate in ("nan", "inf", "-inf", "0", "-1", "fast"):
    check(["--rate", rate], 1, "finite, positive")
for option in ("-v", "--kind", "--rate", "-o"):
    check([option], 1, "requires")
check([], 1, "no text")
check([], 1, "no text", b" \n\t")
check([], 1, "UTF-8", b"\xff")

# An empty terminal session waits for input and exits cleanly on Ctrl-D.
master, slave = pty.openpty()
process = subprocess.Popen([binary], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
os.close(slave)
try:
    try:
        process.wait(timeout=0.5)
        raise AssertionError("Interactive invocation exited before input")
    except subprocess.TimeoutExpired:
        pass
    os.write(master, b"\n\x04")
    stdout, stderr = process.communicate(timeout=10)
    assert process.returncode == 0, stderr
    assert stdout == b"", stdout
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
print("CLI checks passed")
