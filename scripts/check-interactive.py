#!/usr/bin/env python3
"""Real synthesis checks; requires an installed en-US Siri voice."""
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time
import wave

binary = str(Path(sys.argv[1]).resolve())


def frames(path):
    try:
        with wave.open(str(path)) as audio:
            count = audio.getnframes()
            return count if len(audio.readframes(count)) == count * 2 else 0
    except (OSError, EOFError, wave.Error):
        return 0


with tempfile.TemporaryDirectory(prefix="siri-say-interactive-") as directory:
    output = Path(directory) / "speech.wav"
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [binary, "-l", "en-US", "-o", str(output)],
        stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    os.close(slave)
    try:
        time.sleep(0.3)
        assert process.poll() is None and not output.exists()
        previous_frames = 0
        lines = [b"Hello.\n", b"This is a second and substantially longer sentence to verify repeated synthesis.\n"]
        for line in lines:
            os.write(master, line)
            deadline = time.monotonic() + 30
            while frames(output) <= previous_frames:
                assert process.poll() is None, process.stderr.read().decode()
                assert time.monotonic() < deadline, "No audio before EOF"
                time.sleep(0.05)
            previous_frames = frames(output)
            assert process.poll() is None, "Exited after one line"
        os.write(master, b"\x04")
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr.decode()
        assert not stdout, stdout
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)

    # Terminal -o accumulates audio from every line.
    single = Path(directory) / "single.wav"
    subprocess.run([binary, "-l", "en-US", "-o", str(single), lines[-1].decode().strip()], check=True, timeout=30)
    assert frames(output) > frames(single), "Terminal output lost earlier lines"

    for mode in ("paragraph", "line"):
        piped = Path(directory) / f"{mode}.wav"
        process = subprocess.Popen(
            [binary, "--stream", mode, "-l", "en-US", "-o", str(piped)],
            stdin=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            process.stdin.write(b" \n\n" + lines[0])
            process.stdin.flush()
            if mode == "paragraph":
                time.sleep(0.3)
                assert not piped.exists() and process.poll() is None
                process.stdin.write(b"\n")
                process.stdin.flush()
            deadline = time.monotonic() + 30
            while frames(piped) == 0:
                assert process.poll() is None, process.stderr.read().decode()
                assert time.monotonic() < deadline, f"{mode} waited for EOF"
                time.sleep(0.05)
            # EOF must flush a final chunk without a terminating newline.
            _, stderr = process.communicate(lines[1].rstrip(b"\n"), timeout=30)
            assert process.returncode == 0, stderr.decode()
            assert frames(piped) > frames(single)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

print("Interactive lines, accumulated output, EOF, and line/paragraph streaming passed")
