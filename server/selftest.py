#!/usr/bin/env python3
"""Round-trip self test for winremote_server.py.

Starts a real server on a spare port, connects a WebSocket client and checks
the wire protocol end to end.

Only non-destructive commands are used (hello / sysinfo / ping / zero-length
move and scroll), so your real mouse and keyboard are NOT touched.

    py selftest.py
"""

import asyncio
import json
import logging
import sys
import threading
import time
from typing import Any, Dict, List

import winremote_server as srv

PORT = 8799
TOKEN = "selftest"
failures: List[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    status = "PASS" if ok else "FAIL"
    print("  [%s] %s%s" % (status, name, ("  -> " + detail) if detail else ""))
    if not ok:
        failures.append(name)


async def roundtrip() -> None:
    from websockets.asyncio.client import connect

    async with connect("ws://127.0.0.1:%d" % PORT, open_timeout=5) as ws:
        first: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("server announces token requirement",
              first.get("t") == "hello" and first.get("needToken") is True,
              json.dumps(first, ensure_ascii=False))

        await ws.send(json.dumps({"t": "hello", "token": TOKEN}))
        hello: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("hello accepted with correct token",
              hello.get("t") == "hello" and hello.get("ok") is True,
              "host=%s screen=%sx%s" % (hello.get("host"), hello.get("sw"), hello.get("sh")))
        check("hello reports a screen size",
              isinstance(hello.get("sw"), int) and hello.get("sw") > 0)

        await ws.send(json.dumps({"t": "sysinfo"}))
        info: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 10))
        check("sysinfo answered", info.get("t") == "info" and info.get("ok") is True,
              "user=%s" % info.get("user"))

        await ws.send(json.dumps({"t": "ping"}))
        pong: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("ping -> pong", pong.get("t") == "pong")

        # fire-and-forget commands must not produce a reply
        await ws.send(json.dumps({"t": "move", "dx": 0, "dy": 0}))
        await ws.send(json.dumps({"t": "scroll", "dx": 0, "dy": 0}))

        await ws.send(json.dumps({"t": "text", "s": ""}))
        empty: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("empty text acknowledged", empty.get("t") == "textResult", json.dumps(empty))

        await ws.send("not json at all")
        err: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("malformed payload answered with err", err.get("t") == "err", json.dumps(err))

        await ws.send(json.dumps({"t": "definitely-not-a-command"}))
        unknown: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("unknown command answered with err",
              unknown.get("t") == "err", json.dumps(unknown, ensure_ascii=False))


async def bad_token() -> None:
    from websockets.asyncio.client import connect

    try:
        async with connect("ws://127.0.0.1:%d" % PORT, open_timeout=5) as ws:
            await asyncio.wait_for(ws.recv(), 5)          # hello / needToken
            await ws.send(json.dumps({"t": "hello", "token": "wrong"}))
            reply: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 5))
            check("wrong token rejected", reply.get("t") == "err", json.dumps(reply))
            await asyncio.wait_for(ws.recv(), 5)
            check("wrong token closes the socket", False, "connection stayed open")
    except Exception as exc:
        check("wrong token closes the socket", True, type(exc).__name__)


async def streaming() -> None:
    from websockets.asyncio.client import connect

    async with connect("ws://127.0.0.1:%d" % PORT, open_timeout=5) as ws:
        await asyncio.wait_for(ws.recv(), 5)                      # needToken announcement
        await ws.send(json.dumps({"t": "hello", "token": TOKEN}))
        await asyncio.wait_for(ws.recv(), 5)                      # hello ok

        await ws.send(json.dumps({
            "t": "stream", "on": True, "fps": 6, "maxWidth": 640, "quality": 50,
        }))
        state: Dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), 10))
        check("stream start acknowledged",
              state.get("t") == "streamState" and state.get("on") is True,
              "backend=%s" % state.get("backend"))
        check("stream reports capture backend", bool(state.get("backend")))

        frames = 0
        jpeg_ok = True
        biggest = 0
        deadline = time.time() + 20
        while frames < 3 and time.time() < deadline:
            message = await asyncio.wait_for(ws.recv(), 20)
            if isinstance(message, (bytes, bytearray)):
                if len(message) < 4 or message[0] != 0xFF or message[1] != 0xD8:
                    jpeg_ok = False
                biggest = max(biggest, len(message))
                frames += 1
        check("received live screen frames", frames >= 3, "%d frames, largest %d bytes" % (frames, biggest))
        check("frames are JPEG encoded", jpeg_ok)

        await ws.send(json.dumps({"t": "stream", "on": False}))
        stopped: Optional[Dict[str, Any]] = None
        deadline = time.time() + 10
        while time.time() < deadline:
            message = await asyncio.wait_for(ws.recv(), 10)
            if isinstance(message, str):
                parsed: Dict[str, Any] = json.loads(message)
                if parsed.get("t") == "streamState":
                    stopped = parsed
                    break
        check("stream stop acknowledged",
              stopped is not None and stopped.get("on") is False,
              json.dumps(stopped))


def key_resolution() -> None:
    for name in ["enter", "tab", "esc", "f4", "backspace", "space", "a", "5", "win", "ctrl"]:
        try:
            srv.resolve_key(name)
        except Exception as exc:
            check("resolve key %r" % name, False, str(exc))
            return
    check("all named keys resolve", True)

    try:
        srv.resolve_key("not-a-key")
        check("unknown key raises", False, "no exception")
    except ValueError:
        check("unknown key raises", True)


def main() -> int:
    if sys.platform != "win32":
        print("This self test only runs on Windows.")
        return 1

    logging.getLogger().setLevel(logging.WARNING)
    srv.TOKEN = TOKEN

    thread = threading.Thread(
        target=lambda: asyncio.run(srv.run("127.0.0.1", PORT)), daemon=True
    )
    thread.start()
    time.sleep(2.0)

    print("WinRemote server self test")
    print("-" * 52)
    key_resolution()
    try:
        asyncio.run(roundtrip())
        asyncio.run(bad_token())
        asyncio.run(streaming())
    except Exception as exc:
        check("unexpected exception", False, "%s: %s" % (type(exc).__name__, exc))
    print("-" * 52)

    if failures:
        print("FAILED: %d check(s) -> %s" % (len(failures), ", ".join(failures)))
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
