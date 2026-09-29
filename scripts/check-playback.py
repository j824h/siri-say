#!/usr/bin/env python3
"""Real playback and job-control checks; requires en-US Siri voices and audio output."""
import errno
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import sys
import time

binary = str(Path(sys.argv[1]).resolve())
long_text = 'The morning train is arriving at the station and the passengers are gathering their bags. ' * 5


def processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat=,command='], text=True)
    return [row.split(None, 3) for row in rows.splitlines() if len(row.split(None, 3)) == 4]


def alive(pid):
    return any(int(row[0]) == pid and not row[2].startswith('Z') for row in processes())


class Session:
    def __init__(self, text=None, piped=False):
        self.log = b''
        self.events = []
        self.status = None
        self.children = set()
        reader, writer = os.pipe() if piped else (-1, -1)
        self.pid, self.terminal = pty.fork()
        if self.pid == 0:
            if piped:
                os.close(writer)
                os.dup2(reader, 0)
                os.close(reader)
            args = [binary, '--debug', '-l', 'en-US', '--stream', 'line']
            if text is not None:
                args += [text]
            os.execv(binary, args)
        self.writer = writer
        if piped:
            os.close(reader)

    def pump(self):
        if select.select([self.terminal], [], [], .02)[0]:
            try:
                part = os.read(self.terminal, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                part = b''
            if part:
                self.log += part
                self.events.append((time.monotonic(), self.log))
        if self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)

    def until(self, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.pump()
            assert time.monotonic() < deadline, self.log.decode(errors='replace')
        return time.monotonic()

    def playing(self):
        self.until(lambda: b'playback started' in self.log)
        self.children.update(int(row[0]) for row in processes() if int(row[1]) == self.pid)
        assert len(self.children) == 2, self.children

    def key(self, key):
        os.write(self.terminal, key)

    def wait(self, expected, timeout=15):
        self.until(lambda: self.status is not None, timeout)
        assert self.status == expected, (self.status, self.log.decode(errors='replace'))

    def no_workers(self):
        self.until(lambda: not any(alive(pid) for pid in self.children), 4)

    def cleanup(self):
        if self.status is None:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        for pid in self.children:
            if alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if self.writer >= 0:
            os.close(self.writer)
        os.close(self.terminal)


# A short audio buffer must play even while the audio pipe remains open.
p = subprocess.Popen([binary, '--internal-player'], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    p.stdin.write(bytes(960))  # 10 ms, much shorter than the maximum queue buffer
    p.stdin.flush()
    assert select.select([p.stdout], [], [], 5)[0], 'Short audio waited for more input'
    assert p.stdout.readline() == b'playing\n'
    assert p.poll() is None
    p.communicate(timeout=5)
    assert p.returncode == 0
    print('Short audio plays without waiting for another input chunk', flush=True)
finally:
    if p.poll() is None:
        p.kill()
        p.wait()

# Multiple input chunks must overlap generation with existing playback.
s = Session('The morning train arrives at the station and everyone gathers their bags.\nThis is the next chunk.')
try:
    s.playing()
    s.wait(0, 30)
    first_size = int(re.search(rb'queued (\d+) PCM bytes', s.log)[1])
    started = next(t for t, log in s.events if b'playback started' in log)
    next_generation = next(t for t, log in s.events if log.count(b'trying en-US ->') >= 2)
    assert next_generation - started < first_size / 96000 - .5, 'Generation waited for playback'
    s.no_workers()
    print('Generation overlaps playback; normal EOF drains audio', flush=True)
finally:
    s.cleanup()

# Use both interactive input and piped input with a controlling terminal.
for piped, action in [(False, 'stop'), (True, 'detach'), (True, 'drain')]:
    s = Session(piped=piped)
    try:
        os.write(s.writer if piped else s.terminal, (long_text + '\n').encode())
        s.playing()
        s.key(b'\x03')
        s.until(lambda: b'Generation stopped' in s.log)
        if action == 'stop':
            s.key(b'\x03')
            s.wait(130, 3)
        elif action == 'detach':
            s.key(b'\x04')
            s.until(lambda: b'playback continues as PID' in s.log)
            pid = int(re.search(rb'playback continues as PID (\d+)', s.log)[1])
            s.wait(130, 3)
            assert alive(pid), 'Detached player exited with supervisor'
        else:
            s.wait(130, 12)
        # The bounded queue finishes even though the input pipe remains open.
        s.until(lambda: not any(alive(pid) for pid in s.children), 12)
        print(f'Ctrl-C then {action}: passed (piped={piped})', flush=True)
    finally:
        s.cleanup()

for sig in (signal.SIGTERM, signal.SIGKILL):
    s = Session(long_text)
    try:
        s.playing()
        os.kill(s.pid, sig)
        s.wait(143 if sig == signal.SIGTERM else -9, 3)
        s.no_workers()
        print(f'{sig.name}: no surviving workers', flush=True)
    finally:
        s.cleanup()

# Cancellation must also work during a synchronous private synthesis call.
s = Session(long_text)
try:
    s.until(lambda: b'trying en-US ->' in s.log)
    s.children.update(int(row[0]) for row in processes() if int(row[1]) == s.pid)
    s.key(b'\x03')
    s.wait(130, 10)
    s.no_workers()
    print('Ctrl-C during synthesis: workers stopped', flush=True)
finally:
    s.cleanup()

# Noninteractive cancellation must not wait for a terminal choice.
p = subprocess.Popen([binary, '-l', 'en-US', long_text], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
children = set()
try:
    deadline = time.monotonic() + 10
    while len(children) < 2:
        children = {int(row[0]) for row in processes() if int(row[1]) == p.pid}
        assert time.monotonic() < deadline
        time.sleep(.02)
    time.sleep(.2)
    p.send_signal(signal.SIGINT)
    _, stderr = p.communicate(timeout=5)
    assert p.returncode == 130, stderr.decode()
    assert not any(alive(pid) for pid in children)
    print('SIGINT without a controlling terminal: immediate exit', flush=True)
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
    for pid in children:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

# Termination during spawn must not hang on a worker that has not entered main.
for delay in (.01, .03, .05):
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, start_new_session=True)
    try:
        time.sleep(delay)
        children = {int(row[0]) for row in processes() if int(row[1]) == p.pid}
        p.terminate()
        p.communicate(timeout=5)
        assert p.returncode in (-15, 143), p.returncode
        deadline = time.monotonic() + 3
        while any(alive(pid) for pid in children):
            assert time.monotonic() < deadline, 'Worker survived startup cancellation'
            time.sleep(.05)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
print('Cancellation during worker startup: passed', flush=True)
