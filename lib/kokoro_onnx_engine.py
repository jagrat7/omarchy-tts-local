"""Kokoro ONNX synthesis, run with the managed engine's Python.

  once   read text on fd 3, write raw s16le 24 kHz mono PCM to stdout
  serve  keep the model loaded and answer requests on a private unix socket
         until idle for --idle seconds, so an utterance skips the half second
         of model loading
  ask    send fd 3's text to a running server and copy its PCM to stdout;
         exit 75 when no server answers, so the caller can start one

A request is one JSON line {"text", "voice", "speed", "lang"}; the reply is
PCM until the server closes the connection. Stop is a closed connection: the
caller's process group is killed, the server's next write fails, and it drops
the rest of that utterance.
"""
import argparse
import json
import os
import re
import select
import signal
import socket
import struct
import sys
import time

RATE = 24000
REQUEST_MAX_BYTES = 2_097_152


def chunks(source: str) -> list[str]:
    """Sentence-sized pieces, so playback starts after the first one instead
    of after the whole selection. kokoro-onnx's own streaming batches by
    phoneme count (about 500), which makes an ordinary paragraph one batch.
    The first piece is cut at a clause when long, since only it is waited on;
    later ones are synthesised while earlier ones play."""
    pieces = [p.strip() for p in re.split(r"(?<=[.!?;:])\s+|\n+", source) if p.strip()]
    merged: list[str] = []
    for piece in pieces:
        # Fragments like "Fig. 3." sound clipped alone; keep them with a neighbour.
        if merged and len(merged[-1]) < 24:
            merged[-1] += " " + piece
        else:
            merged.append(piece)
    if merged and len(merged[0]) > 60:
        cut = re.search(r"(?<=[,;])\s+", merged[0][20:])
        if cut:
            at = 20 + cut.end()
            merged[0:1] = [merged[0][:at].strip(), merged[0][at:].strip()]
    return merged


def load(models: str, device: str):
    import onnxruntime as ort
    from kokoro_onnx import Kokoro

    providers = ["CPUExecutionProvider"]
    if device == "gpu":
        # The CUDA and cuDNN libraries come from the engine's own nvidia-* wheels.
        if hasattr(ort, "preload_dlls"):
            ort.preload_dlls()
        if "CUDAExecutionProvider" in ort.get_available_providers():
            providers.insert(0, "CUDAExecutionProvider")
    options = ort.SessionOptions()
    options.log_severity_level = 3
    session = ort.InferenceSession(os.path.join(models, "kokoro-v1.0.onnx"), options,
                                   providers=providers)
    return Kokoro.from_session(session, os.path.join(models, "voices-v1.0.bin"))


def synthesise(kokoro, request: dict, write) -> None:
    import numpy as np

    voice = request["voice"]
    if not re.fullmatch(r"[a-z]{2}_[a-z]+", voice):
        raise ValueError("invalid voice name")
    speed = min(2.0, max(0.5, float(request.get("speed", 1.0))))
    lang = "en-gb" if request.get("lang") == "en-gb" else "en-us"
    style = kokoro.get_voice_style(voice)
    for index, piece in enumerate(chunks(str(request["text"]))):
        samples, rate = kokoro.create(piece, voice=style, speed=speed, lang=lang)
        if index:
            # create() trims edge silence; restore the gap between sentences.
            write(np.zeros(int(rate * 0.2 / speed), dtype="<i2").tobytes())
        clipped = np.clip(np.asarray(samples, dtype="float32"), -1.0, 1.0)
        write((clipped * 32767.0).astype("<i2").tobytes())


def read_request_fd3(args) -> dict:
    with os.fdopen(3, encoding="utf-8") as source:
        text = source.read(REQUEST_MAX_BYTES)
    return {"text": text, "voice": args.voice, "speed": args.speed, "lang": args.lang}


def once(args) -> int:
    kokoro = load(args.models, args.device)
    request = read_request_fd3(args)

    def write(data: bytes) -> None:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

    synthesise(kokoro, request, write)
    return 0


def ask(args) -> int:
    request = read_request_fd3(args)
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.connect(args.socket)
    except OSError:
        return 75
    with client:
        # The request is the user's text. A server run by another account
        # gets nothing; 75 makes the provider start its own.
        if not peer_is_owner(client):
            return 75
        client.sendall(json.dumps(request).encode() + b"\n")
        received = 0
        while True:
            data = client.recv(65536)
            if not data:
                break
            received += len(data)
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
    # An empty reply to non-empty text means the server failed the request.
    return 0 if received or not request["text"].strip() else 1


def peer_is_owner(connection: socket.socket) -> bool:
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                        struct.calcsize("3i"))
    _pid, uid, _gid = struct.unpack("3i", credentials)
    return uid == os.getuid()


def read_line(connection: socket.socket) -> bytes:
    data = b""
    connection.settimeout(5)
    while b"\n" not in data:
        chunk = connection.recv(65536)
        if not chunk:
            break
        data += chunk
        if len(data) > REQUEST_MAX_BYTES:
            raise ValueError("request too large")
    connection.settimeout(None)
    return data.split(b"\n", 1)[0]


def serve(args) -> int:
    os.umask(0o077)
    kokoro = load(args.models, args.device)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    staging = f"{args.socket}.{os.getpid()}"
    try:
        os.unlink(staging)
    except FileNotFoundError:
        pass
    listener.bind(staging)
    listener.listen(4)
    # Publish only a socket that is already accepting, under the final name.
    os.replace(staging, args.socket)
    published = os.stat(args.socket).st_ino
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    last_used = time.monotonic()
    try:
        while True:
            remaining = args.idle - (time.monotonic() - last_used)
            if remaining <= 0:
                return 0
            ready, _, _ = select.select([listener], [], [], remaining)
            if not ready:
                continue
            connection, _ = listener.accept()
            with connection:
                try:
                    if not peer_is_owner(connection):
                        continue
                    request = json.loads(read_line(connection))
                    if not isinstance(request, dict) or not isinstance(request.get("text"), str):
                        continue
                    synthesise(kokoro, request, connection.sendall)
                except (OSError, ValueError, KeyError, TypeError):
                    # A closed connection is Stop; a malformed request gets
                    # silence. Neither should take the warm engine down.
                    pass
            last_used = time.monotonic()
    finally:
        # Remove the socket only while it is still ours; a newer server may
        # have replaced it.
        try:
            if os.stat(args.socket).st_ino == published:
                os.unlink(args.socket)
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("once", "serve", "ask"))
    parser.add_argument("--models", default="")
    parser.add_argument("--device", choices=("cpu", "gpu"), default="cpu")
    parser.add_argument("--socket", default="")
    parser.add_argument("--idle", type=float, default=600)
    parser.add_argument("--voice", default="af_heart")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--lang", default="en-us")
    args = parser.parse_args()
    return {"once": once, "serve": serve, "ask": ask}[args.mode](args)


if __name__ == "__main__":
    sys.exit(main())
