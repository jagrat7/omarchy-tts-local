#!/usr/bin/env python3
"""Private mpv registration and bounded JSON IPC for the speech CLI."""
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import struct
import sys
import tempfile

os.umask(0o077)


def read(path, maximum=32768):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("unsafe playback state")
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("oversized playback state")
    return data.decode()


def write(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".playback-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def identity(pid):
    fields = Path(f"/proc/{int(pid)}/stat").read_text().rsplit(") ", 1)[1].split()
    if fields[0] == "Z":
        raise ValueError("dead playback process")
    return fields[19], int(fields[2])


def live_owner(state):
    owner = read(state / "pgid", 256).strip()
    pid, start = owner.split()
    if identity(pid) != (start, int(pid)):
        raise ValueError("stale playback owner")
    return owner


def session_dir(state, name):
    if not re.fullmatch(r"\.player\.[A-Za-z0-9]+", name):
        raise ValueError("invalid playback session")
    directory = state / name
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("unsafe playback session")
    return directory


def cleanup(directory):
    for name in ("player.json", "ipc"):
        (directory / name).unlink(missing_ok=True)
    directory.rmdir()


class Ipc:
    def __init__(self, state, metadata):
        owner = live_owner(state)
        if metadata["owner"] != owner:
            raise ValueError("superseded playback")
        directory = session_dir(state, metadata["session"])
        player = json.loads(read(directory / "player.json", 1024))
        start, group = identity(player["pid"])
        if start != player["identity"] or group != int(owner.split()[0]):
            raise ValueError("stale player identity")
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(0.12)
        try:
            self.sock.connect(str(directory / "ipc"))
            pid, uid, _ = struct.unpack("3i", self.sock.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            if pid != player["pid"] or uid != os.getuid():
                raise ValueError("unexpected IPC peer")
            if identity(pid) != (start, group):
                raise ValueError("replaced IPC peer")
            self.stream = self.sock.makefile("rb")
        except BaseException:
            self.sock.close()
            raise
        self.sequence = 0

    def close(self):
        self.stream.close()
        self.sock.close()

    def command(self, *command):
        self.sequence += 1
        self.sock.sendall((json.dumps({"command": command, "request_id": self.sequence}) + "\n").encode())
        # mpv may interleave events with replies. Bound both line and count.
        for _ in range(32):
            line = self.stream.readline(65537)
            if not line or len(line) > 65536:
                raise ValueError("invalid IPC response")
            response = json.loads(line)
            if response.get("request_id") == self.sequence:
                if response.get("error") != "success":
                    return None
                return response.get("data", True)
        raise ValueError("missing IPC response")


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def main():
    action, location, *args = sys.argv[1:]
    state = Path(location)
    metadata_path = state / "now-playing.json"
    if action == "player":
        # exec preserves this identity, including when a provider pipes to us.
        start, _ = identity(os.getpid())
        write(state / "player.json", {"pid": os.getpid(), "identity": start})
        rate, channels = args
        os.execvp("mpv", ["mpv", "--no-config", "--load-scripts=no", "--osc=no",
                  "--ytdl=no", "--terminal=no", "--really-quiet", "--video=no",
                  "--audio-display=no", "--input-default-bindings=no",
                  "--input-terminal=no", "--cache=no", "--cache-pause=no",
                  "--audio-buffer=0.04", "--audio-pitch-correction=yes",
                  # Short overlaps keep control latency low on streamed PCM.
                  "--af=scaletempo2=search-interval=10:min-speed=0.01:max-speed=0",
                  f"--input-ipc-server={state / 'ipc'}",
                  "--demuxer=lavf", "--demuxer-lavf-format=s16le",
                  f"--demuxer-lavf-o=sample_rate={rate},ch_layout={channels}c",
                  "--demuxer-lavf-probe-info=no", "--demuxer-lavf-buffersize=4096", "-"])
    if action == "init":
        owner, session, rate, provider, voice = args
        text = sys.stdin.read(1048577).removesuffix("\n")
        write(metadata_path, {"owner": owner, "session": session,
              "text": text[:4096], "chars": len(text), "baseRate": float(rate),
              "rate": float(rate), "provider": provider, "voice": voice})
        return
    if action == "cleanup-dir":
        cleanup(state)
        return
    if action == "clear":
        try:
            metadata = json.loads(read(metadata_path))
            cleanup(session_dir(state, metadata["session"]))
        except (OSError, ValueError, KeyError, TypeError):
            pass
        metadata_path.unlink(missing_ok=True)
        return
    try:
        configured_rate = float(args[0]) if args else 1.0
        if not math.isfinite(configured_rate) or not 0.25 <= configured_rate <= 4:
            configured_rate = 1.0
    except ValueError:
        configured_rate = 1.0
    result = {"status": "idle", "text": "", "chars": 0, "elapsed": None,
              "duration": None, "rate": configured_rate,
              "provider": args[1] if len(args) > 1 else "", "voice": "",
              "canPause": False, "canLiveRate": False}
    ipc = None
    try:
        owner = live_owner(state)
        result["status"] = "speaking"
        metadata = json.loads(read(metadata_path))
        if metadata["owner"] != owner:
            raise ValueError("superseded metadata")
        for key in ("text", "chars", "rate", "provider", "voice"):
            result[key] = metadata[key]
        try:
            ipc = Ipc(state, metadata)
        except (OSError, ValueError, KeyError, TypeError):
            pass
        if ipc:
            if action in ("pause", "resume", "toggle-pause"):
                paused = ipc.command("get_property", "pause")
                target = not paused if action == "toggle-pause" else action == "pause"
                if ipc.command("set_property", "pause", target) is not None:
                    write_status = state / "status"
                    fd, temporary = tempfile.mkstemp(prefix=".status-", dir=state)
                    with os.fdopen(fd, "w") as stream:
                        stream.write("paused\n" if target else "speaking\n")
                    os.replace(temporary, write_status)
            elif action == "live-rate":
                rate = float(args[0])
                if ipc.command("set_property", "speed", rate / metadata["baseRate"]) is not None:
                    metadata["rate"] = rate
                    write(metadata_path, metadata)
                    print(json.dumps({"rate": rate, "applied": "live"}))
                    return
            elif action == "state":
                result["canPause"] = result["canLiveRate"] = True
                result["status"] = "paused" if ipc.command("get_property", "pause") else "speaking"
                position = ipc.command("get_property", "audio-pts")
                if number(position):
                    result["elapsed"] = max(0, position * metadata["baseRate"])
                # A pipe's reported duration is only the bytes buffered so far.
                result["duration"] = max(metadata["chars"] / 15, result["elapsed"] or 0)
    except (OSError, ValueError, KeyError, TypeError):
        try:
            pid, start = read(state / "preparing", 256).split()
            if identity(pid) == (start, int(pid)):
                result["status"] = "preparing"
        except (OSError, ValueError):
            pass
    finally:
        if ipc:
            ipc.close()
    if action == "state":
        print(json.dumps(result, ensure_ascii=False))
    elif action == "live-rate":
        print(json.dumps({"rate": float(args[0]), "applied": "next"}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"speak: playback unavailable: {error}", file=sys.stderr)
        sys.exit(1)
