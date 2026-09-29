#!/usr/bin/env python3
"""WinRemote LAN server.

Runs on a Windows 11 PC, accepts WebSocket connections from the WinRemote
HarmonyOS app on the same LAN, and injects mouse / keyboard input.

Quick start (PowerShell, on the Windows 11 PC):

    py -m pip install -r requirements.txt
    py winremote_server.py --port 8765 --token 1234

The script prints every LAN IPv4 address of this PC; type one of them into
the app together with the port and the token.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import ctypes
import io
import json
import logging
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List, Optional

APP_VERSION = "1.0.0"
DEFAULT_PORT = 8765

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("winremote")

def fatal(message: str) -> None:
    """Log a fatal error and, when running as a double-clicked .exe, keep the
    console window open so the user can actually read the message."""
    log.error(message)
    if getattr(sys, "frozen", False):
        try:
            input("\nPress Enter to exit ...")
        except Exception:
            pass
    sys.exit(1)


if sys.platform != "win32":
    fatal("This server only supports Windows (input injection uses Win32 APIs).")

try:
    from pynput.keyboard import Controller as KeyboardController, Key
    from pynput.mouse import Button, Controller as MouseController
except ImportError as exc:  # pragma: no cover
    fatal("Missing dependency %s -- install it with:  py -m pip install pynput" % exc)


# --------------------------------------------------------------------------- #
# input backend
# --------------------------------------------------------------------------- #

keyboard = KeyboardController()
mouse = MouseController()

BUTTONS: Dict[str, Button] = {
    "left": Button.left,
    "right": Button.right,
    "middle": Button.middle,
}

SPECIAL_KEYS: Dict[str, Any] = {
    "enter": Key.enter,
    "return": Key.enter,
    "esc": Key.esc,
    "escape": Key.esc,
    "tab": Key.tab,
    "backspace": Key.backspace,
    "bs": Key.backspace,
    "delete": Key.delete,
    "del": Key.delete,
    "space": Key.space,
    "up": Key.up,
    "down": Key.down,
    "left": Key.left,
    "right": Key.right,
    "home": Key.home,
    "end": Key.end,
    "pageup": Key.page_up,
    "pagedown": Key.page_down,
    "insert": Key.insert,
    "printscreen": Key.print_screen,
    "win": Key.cmd,
    "cmd": Key.cmd,
    "super": Key.cmd,
    "meta": Key.cmd,
    "ctrl": Key.ctrl,
    "control": Key.ctrl,
    "alt": Key.alt,
    "shift": Key.shift,
    "capslock": Key.caps_lock,
    "menu": Key.menu,
}
for _i in range(1, 13):
    SPECIAL_KEYS["f%d" % _i] = getattr(Key, "f%d" % _i)

MODIFIER_NAMES = {
    "ctrl", "control", "alt", "shift", "win", "cmd", "super", "meta",
}


def screen_size() -> tuple:
    """Primary monitor size in physical pixels (DPI aware)."""
    try:
        user32 = ctypes.windll.user32
        user32.SetProcessDPIAware()
        return int(user32.GetSystemMetrics(0)), int(user32.GetSystemMetrics(1))
    except Exception:
        return 0, 0


TOKEN_QUERY = 0x0008
TOKEN_INTEGRITY_LEVEL = 25
SECURITY_MANDATORY_HIGH_RID = 0x3000


def own_integrity_rid() -> Optional[int]:
    """Integrity level RID of this process (0x2000 medium, 0x3000 high)."""
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)

        kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        advapi32.OpenProcessToken.argtypes = [
            ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p),
        ]
        advapi32.OpenProcessToken.restype = ctypes.c_int
        advapi32.GetTokenInformation.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32),
        ]
        advapi32.GetTokenInformation.restype = ctypes.c_int

        token = ctypes.c_void_p()
        process = kernel32.GetCurrentProcess()
        if not advapi32.OpenProcessToken(process, TOKEN_QUERY, ctypes.byref(token)):
            return None
        try:
            needed = ctypes.c_uint32(0)
            advapi32.GetTokenInformation(
                token, TOKEN_INTEGRITY_LEVEL, None, 0, ctypes.byref(needed)
            )
            if not needed.value:
                return None
            buffer = ctypes.create_string_buffer(needed.value)
            if not advapi32.GetTokenInformation(
                token, TOKEN_INTEGRITY_LEVEL, buffer, needed.value,
                ctypes.byref(needed),
            ):
                return None
            # TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES { PSID Sid; DWORD Attrs } }
            # The last sub-authority of that SID is the integrity level.
            sid = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_void_p))[0]
            count = ctypes.cast(sid, ctypes.POINTER(ctypes.c_ubyte))[1]
            last = ctypes.cast(
                sid + 8 + (count - 1) * 4, ctypes.POINTER(ctypes.c_uint32)
            )[0]
            return int(last)
        finally:
            kernel32.CloseHandle(token)
    except Exception:
        return None


def is_elevated() -> Optional[bool]:
    """True when running as administrator; None when it cannot be determined.

    Windows UIPI drops the input this server injects while an elevated window
    owns the foreground, so this is checked up front and reported loudly.
    """
    rid = own_integrity_rid()
    if rid is None:
        return None
    return rid >= SECURITY_MANDATORY_HIGH_RID


def resolve_key(name: str) -> Any:
    low = name.strip().lower()
    if low in SPECIAL_KEYS:
        return SPECIAL_KEYS[low]
    if len(name) == 1:
        return name
    raise ValueError("unknown key: %r" % name)


def tap_key(name: str) -> None:
    key = resolve_key(name)
    keyboard.press(key)
    keyboard.release(key)


def press_combo(names: List[str]) -> None:
    if not names:
        return
    resolved = [resolve_key(n) for n in names]
    modifiers = resolved[:-1]
    final = resolved[-1]
    for mod in modifiers:
        keyboard.press(mod)
    keyboard.press(final)
    keyboard.release(final)
    for mod in reversed(modifiers):
        keyboard.release(mod)


def set_clipboard(text: str) -> bool:
    """Put text on the Windows clipboard (works for CJK, unlike key typing)."""
    try:
        subprocess.run(
            [
                "powershell", "-NoProfile", "-NonInteractive", "-Command",
                "$in = [Console]::In.ReadToEnd(); Set-Clipboard -Value $in",
            ],
            input=text,
            text=True,
            encoding="utf-8",
            timeout=15,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return True
    except Exception as exc:
        log.warning("clipboard write failed: %s", exc)
        return False


def type_text(text: str) -> bool:
    """Type arbitrary text. ASCII goes through the keyboard, CJK via clipboard."""
    if not text:
        return True
    if all(ord(ch) < 128 for ch in text):
        try:
            keyboard.type(text)
            return True
        except Exception as exc:
            log.warning("keyboard.type failed: %s", exc)
    if set_clipboard(text):
        press_combo(["ctrl", "v"])
        return True
    return False


# --------------------------------------------------------------------------- #
# protocol
# --------------------------------------------------------------------------- #

def sys_info() -> Dict[str, Any]:
    hostname = socket.gethostname()
    user = "unknown"
    try:
        user = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", "$env:USERNAME"],
            capture_output=True, text=True, timeout=10,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout.strip() or "unknown"
    except Exception:
        pass
    width, height = screen_size()
    return {
        "t": "info",
        "ok": True,
        "server": "WinRemote/%s" % APP_VERSION,
        "host": hostname,
        "user": user,
        "os": "Windows",
        "sw": width,
        "sh": height,
    }


def dispatch(cmd: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Execute one command. Returns a reply message, or None for fire-and-forget."""
    kind = str(cmd.get("t", ""))

    if kind == "move":
        mouse.move(int(cmd.get("dx", 0)), int(cmd.get("dy", 0)))
        return None

    if kind == "moveto":
        width, height = screen_size()
        if width and height:
            # The mouse API may work in a DPI scaled space while GetSystemMetrics
            # reports physical pixels; the scale cancels out for normalised
            # coordinates. Stay just inside the edge so Windows never has to
            # clamp a coordinate onto the boundary.
            nx = min(max(float(cmd.get("x", 0.0)), 0.0), 0.999)
            ny = min(max(float(cmd.get("y", 0.0)), 0.0), 0.999)
            mouse.position = (int(nx * width), int(ny * height))
        return None

    if kind == "click":
        button = BUTTONS.get(str(cmd.get("b", "left")).lower(), Button.left)
        action = str(cmd.get("a", "click")).lower()
        if action == "down":
            mouse.press(button)
        elif action == "up":
            mouse.release(button)
        else:
            mouse.press(button)
            mouse.release(button)
        return None

    if kind == "scroll":
        mouse.scroll(int(cmd.get("dx", 0)), int(cmd.get("dy", 0)))
        return None

    if kind == "key":
        tap_key(str(cmd.get("k", "")))
        return None

    if kind == "combo":
        raw = cmd.get("keys")
        names = [str(item) for item in raw] if isinstance(raw, list) else []
        press_combo(names)
        return None

    if kind == "text":
        ok = type_text(str(cmd.get("s", "")))
        return {"t": "textResult", "ok": ok}

    if kind == "sysinfo":
        return sys_info()

    if kind == "ping":
        return {"t": "pong", "ts": int(time.time() * 1000)}

    return {"t": "err", "msg": "unknown command: %s" % kind}


# --------------------------------------------------------------------------- #
# screen capture
# --------------------------------------------------------------------------- #

try:
    from PIL import Image as PILImage
except ImportError as exc:  # pragma: no cover
    fatal("Missing dependency %s -- install it with:  py -m pip install Pillow" % exc)


class ScreenCapturer:
    """Grabs the primary screen.

    Backends, best first:

    ``wgc``    Windows.Graphics.Capture via the ``windows-capture`` package.
               A Rust extension that hands frames over zero-copy on its own
               capture thread, so the server thread only pays for the JPEG
               encode. It also only reports frames when the desktop actually
               changes. Unlike COM-based duplication (bettercam/DXGI) this keeps
               working inside a PyInstaller bundle.
    ``mss``    GDI BitBlt through mss.
    ``pillow`` PIL.ImageGrab, last resort.

    An ``mss`` instance is bound to the thread that created it, so every capture
    runs on one dedicated worker thread and it is created lazily on that same
    thread. The WGC capture thread is started lazily on the first grab.
    """

    STARTUP_GRACE = 10.0

    def __init__(self) -> None:
        self._local = threading.local()
        self.backend = "mss"
        self._control = None
        self._frame = None
        self._frame_error = None
        self._frame_lock = threading.Lock()
        self._since = None
        try:
            import windows_capture  # noqa: F401
            self.backend = "wgc"
        except ImportError:
            pass
        if self.backend != "wgc":
            try:
                import mss  # noqa: F401
            except ImportError:
                self.backend = "pillow"

    def _reader(self):
        reader = getattr(self._local, "reader", None)
        if reader is None:
            if self.backend == "mss":
                import mss
                reader = mss.MSS() if hasattr(mss, "MSS") else mss.mss()
            else:
                from PIL import ImageGrab
                reader = ImageGrab
            self._local.reader = reader
        return reader

    def _wgc_control(self):
        if self._control is None:
            import numpy as np
            from windows_capture import WindowsCapture

            capture = WindowsCapture(
                cursor_capture=False, draw_border=False, monitor_index=1
            )

            @capture.event
            def on_frame_arrived(frame, capture_control):
                try:
                    # BGRA, valid only inside this callback -- copy it out and
                    # swap the channels in one pass.
                    array = np.asarray(frame.frame_buffer)
                    image = PILImage.fromarray(
                        np.ascontiguousarray(array[:, :, 2::-1])
                    )
                except Exception as exc:  # keep the stream alive
                    self._frame_error = exc
                    return
                with self._frame_lock:
                    self._frame = image

            @capture.event
            def on_closed():
                pass

            self._control = capture.start_free_threaded()
            log.info("WGC capture started (Windows.Graphics.Capture, RGB)")
        return self._control

    def _use_fallback(self, reason: str) -> None:
        log.warning("WGC unavailable (%s); falling back to mss", reason)
        control = self._control
        self._control = None
        self.backend = "mss"
        if control is not None:
            try:
                control.stop()
            except Exception:
                pass

    def grab(self):
        if self.backend == "wgc":
            if self._since is None:
                self._since = time.monotonic()
            try:
                self._wgc_control()
                with self._frame_lock:
                    image = self._frame
                if image is not None:
                    self._since = time.monotonic()
                    return image
                if self._frame_error is not None:
                    self._use_fallback(str(self._frame_error))
                elif time.monotonic() - self._since > self.STARTUP_GRACE:
                    self._use_fallback(
                        "no frame within %.0fs" % self.STARTUP_GRACE
                    )
            except Exception as exc:
                self._use_fallback(str(exc))

        reader = self._reader()
        if self.backend == "mss":
            monitor = reader.monitors[1]
            shot = reader.grab(monitor)
            return PILImage.frombytes("RGB", shot.size, shot.rgb)
        return reader.grab()


def encode_jpeg(image, max_width: int, quality: int) -> tuple:
    """Downscale (when asked) and JPEG encode. ``max_width <= 0`` keeps native size.

    A power-of-two downscale uses ``reduce()``, which is roughly six times faster
    than a general ``resize()`` on this class of machine. The general path uses
    BOX (area average), which is both the correct filter for shrinking and about
    30% faster than BILINEAR here.
    """
    if max_width and image.width > max_width:
        factor = image.width // max_width
        if factor >= 2 and abs(image.width / factor - max_width) <= 2:
            image = image.reduce(factor)
        else:
            ratio = max_width / float(image.width)
            image = image.resize(
                (max_width, max(1, int(image.height * ratio))), PILImage.BOX
            )
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=quality, optimize=False)
    return buffer.getvalue(), image.width, image.height


CAPTURER = ScreenCapturer()
CAPTURE_POOL = ThreadPoolExecutor(max_workers=1, thread_name_prefix="capture")


def capture_jpeg(max_width: int, quality: int) -> tuple:
    """Grab the screen and encode it. Runs on the dedicated worker thread.

    Capture and encoding deliberately share one thread: screen capture is
    GIL-bound here, so running them concurrently in separate threads measurably
    *lowers* throughput (contention roughly halves the frame rate).
    """
    image = CAPTURER.grab()
    return encode_jpeg(image, max_width, quality)


async def grab_jpeg(max_width: int, quality: int) -> tuple:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(CAPTURE_POOL, capture_jpeg, max_width, quality)


# --------------------------------------------------------------------------- #
# H.264 encoding (PyAV): hardware first (Media Foundation / NVENC), then x264
# --------------------------------------------------------------------------- #

H264_ENCODER_CANDIDATES = ("h264_mf", "h264_nvenc", "libx264")
H264_SUPPORTED = False
try:
    import av  # noqa: F401
    for _name in H264_ENCODER_CANDIDATES:
        try:
            av.codec.Codec(_name, "w")
            H264_SUPPORTED = True
            break
        except Exception:
            continue
except ImportError:
    pass


def h264_bitrate(quality: int, width: int, height: int, fps: int) -> int:
    """Map the client's quality knob (10..95) to a bitrate in bits/second."""
    base = 6_000_000 if quality <= 50 else (10_000_000 if quality <= 70 else 18_000_000)
    scale = (width * height * max(1, fps)) / (1920.0 * 1080.0 * 30.0)
    return clamp(int(base * max(0.3, min(scale, 4.0))), 500_000, 80_000_000)


def avcc_to_annexb(data: bytes) -> bytes:
    """Convert AVCC extradata (avcC box) to Annex B start-code format."""
    if not data or len(data) < 7:
        return b""
    if data[:4] == b"\x00\x00\x00\x01" or data[:3] == b"\x00\x00\x01":
        return bytes(data)
    out = []
    try:
        length_size = (data[4] & 0x03) + 1
        i = 5
        num_sps = data[i] & 0x1F
        i += 1
        for _ in range(num_sps):
            n = int.from_bytes(data[i:i + 2], "big")
            i += 2
            out.append(b"\x00\x00\x00\x01" + data[i:i + n])
            i += n
        num_pps = data[i]
        i += 1
        for _ in range(num_pps):
            n = int.from_bytes(data[i:i + 2], "big")
            i += 2
            out.append(b"\x00\x00\x00\x01" + data[i:i + n])
            i += n
        return b"".join(out)
    except Exception:
        return b""


class H264Encoder:
    """One H.264 encode context per session.

    Lives entirely on the CAPTURE_POOL worker thread. Produces Annex B NAL
    units (one access unit per encode() call in the low-latency configuration:
    no B-frames, headers repeated before each IDR where the encoder does so).
    """

    def __init__(self, width: int, height: int, fps: int, bitrate: int) -> None:
        import av
        from fractions import Fraction

        self.params = (width, height, fps, bitrate)
        self.width = width - (width % 2)
        self.height = height - (height % 2)
        self.fps = max(1, min(fps, 60))
        self.pts = 0
        self.name = "none"
        codec = None
        for name in H264_ENCODER_CANDIDATES:
            try:
                codec = av.codec.Codec(name, "w")
                self.name = name
                break
            except Exception:
                continue
        if codec is None:
            raise RuntimeError("no H.264 encoder available")

        ctx = codec.create()
        ctx.width = self.width
        ctx.height = self.height
        ctx.pix_fmt = "yuv420p"
        ctx.time_base = Fraction(1, self.fps)
        ctx.framerate = Fraction(self.fps, 1)
        ctx.bit_rate = bitrate
        ctx.gop_size = max(1, self.fps)
        if self.name == "libx264":
            ctx.options = {"preset": "ultrafast", "tune": "zerolatency"}
        elif self.name == "h264_mf":
            ctx.options = {"rate_control": "cbr"}
        ctx.open()
        self.ctx = ctx
        self.header = avcc_to_annexb(bytes(ctx.extradata or b""))
        self.header_sent = False
        log.info("H264 encoder started: %s %dx%d fps=%d bitrate=%d",
                 self.name, self.width, self.height, self.fps, bitrate)

    def encode(self, image) -> bytes:
        """Encode one RGB PIL image; returns one Annex B access unit (may be empty)."""
        import av
        import numpy as np

        if image.width != self.width or image.height != self.height:
            image = image.resize((self.width, self.height))
        array = np.asarray(image)
        frame = av.VideoFrame.from_ndarray(array, format="rgb24")
        frame = frame.reformat(format="yuv420p")
        frame.pts = self.pts
        self.pts += 1
        chunks = []
        for packet in self.ctx.encode(frame):
            chunks.append(bytes(packet))
        if not chunks:
            return b""
        payload = b"".join(chunks)
        if not self.header_sent:
            if self.header:
                payload = self.header + payload
            self.header_sent = True
        return payload

    def close(self) -> None:
        try:
            self.ctx.close()
        except Exception:
            pass


def scale_image(image, max_width: int):
    """Shared downscale path for JPEG and H.264 (see encode_jpeg notes)."""
    if max_width and image.width > max_width:
        factor = image.width // max_width
        if factor >= 2 and abs(image.width / factor - max_width) <= 2:
            return image.reduce(factor)
        ratio = max_width / float(image.width)
        return image.resize((max_width, max(1, int(image.height * ratio))), PILImage.BOX)
    return image


def capture_h264_blocking(session: "Session") -> tuple:
    """Grab the screen and H.264 encode it, on the dedicated worker thread."""
    image = CAPTURER.grab()
    image = scale_image(image, session.max_width)
    bitrate = h264_bitrate(session.quality, image.width, image.height, session.fps)
    params = (image.width, image.height, session.fps, bitrate)
    if session.h264_encoder is None or session.h264_encoder.params != params:
        old = session.h264_encoder
        session.h264_encoder = H264Encoder(image.width, image.height, session.fps, bitrate)
        if old is not None:
            old.close()
    payload = session.h264_encoder.encode(image)
    return payload, image.width, image.height


async def grab_h264(session: "Session") -> tuple:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(CAPTURE_POOL, capture_h264_blocking, session)


# --------------------------------------------------------------------------- #
# transport
# --------------------------------------------------------------------------- #

DEFAULT_FPS = 20
DEFAULT_QUALITY = 70
DEFAULT_MAX_WIDTH = 1280     # 0 = keep the screen's native resolution
MAX_FPS = 60
ACK_TIMEOUT = 0.5            # seconds to wait for a client's consumption report


def clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


class Session:
    def __init__(self, websocket: Any) -> None:
        self.ws = websocket
        self.authed = False
        self.streaming = False
        self.codec = "jpeg"
        self.fps = DEFAULT_FPS
        self.quality = DEFAULT_QUALITY
        self.max_width = DEFAULT_MAX_WIDTH
        self.ack_mode = False
        self.acks = 0
        self.ack_cond = asyncio.Condition()
        self.send_lock = asyncio.Lock()
        self.task: Optional[asyncio.Task] = None
        self.h264_encoder: Optional[H264Encoder] = None
        addr = getattr(websocket, "remote_address", None)
        self.peer = "%s:%s" % (addr[0], addr[1]) if addr else "unknown"


async def send_json(session: Session, payload: Dict[str, Any]) -> None:
    try:
        async with session.send_lock:
            await session.ws.send(json.dumps(payload, ensure_ascii=False))
    except Exception as exc:
        log.debug("send failed: %s", exc)


async def send_frame(session: Session, frame: bytes) -> None:
    async with session.send_lock:
        await session.ws.send(frame)


async def signal_ack(session: Session) -> None:
    """Record that the client has finished displaying one more frame."""
    async with session.ack_cond:
        session.acks += 1
        session.ack_cond.notify_all()


async def wait_ack_after(session: Session, base: int, timeout: float) -> bool:
    """Block until the client reports consuming at least one frame since ``base``.

    Deliberately a credit test (``acks > base``) rather than an exact tally
    (``acks >= sent``): a lost or coalesced ack then costs one extra frame in
    flight instead of permanently shifting the counters, which would degrade the
    stream to one frame per timeout for the rest of the session.
    """
    async with session.ack_cond:
        try:
            await asyncio.wait_for(
                session.ack_cond.wait_for(lambda: session.acks > base), timeout
            )
            return True
        except asyncio.TimeoutError:
            return False


async def stream_loop(session: Session) -> None:
    """Pushes JPEG frames until streaming is switched off or the peer goes away.

    In ``ack_mode`` the client reports every frame it has finished showing and
    this loop waits for such a report before sending the next one. Without it the
    server keeps pushing at ``fps`` no matter how far behind the client is, and
    the backlog that builds up in the socket / Wi-Fi buffers is exactly what the
    user perceives as seconds of lag.

    The capture of the next frame is started *before* the wait, so encoding
    overlaps with the client's own decode time instead of being serialised after
    it.
    """
    log.info("stream started for %s (%s fps, %s px, q%d, ack=%s, codec=%s)",
             session.peer, session.fps,
             "native" if not session.max_width else session.max_width,
             session.quality, session.ack_mode, session.codec)
    try:
        sent = 0
        ack_base = session.acks
        while session.streaming:
            started = time.monotonic()
            if session.codec == "h264":
                capture = asyncio.ensure_future(grab_h264(session))
            else:
                capture = asyncio.ensure_future(
                    grab_jpeg(session.max_width, session.quality)
                )

            if session.ack_mode and sent > 0:
                if not await wait_ack_after(session, ack_base, ACK_TIMEOUT):
                    log.debug("client %s did not report frame %d in %.2fs",
                              session.peer, sent, ACK_TIMEOUT)
                ack_base = session.acks

            try:
                frame, width, height = await capture
            except Exception as exc:
                log.warning("capture failed: %s", exc)
                await asyncio.sleep(0.4)
                continue

            if not session.streaming:
                break

            if not frame:
                # Encoders occasionally emit nothing for an input frame
                # (pipeline warm-up); just grab the next one.
                continue

            try:
                await send_frame(session, frame)
            except Exception as exc:
                log.debug("frame send failed: %s", exc)
                break
            sent += 1

            delay = (1.0 / max(1, session.fps)) - (time.monotonic() - started)
            if delay > 0:
                await asyncio.sleep(delay)
    finally:
        session.streaming = False
        log.info("stream stopped for %s", session.peer)


def stop_stream(session: Session) -> None:
    session.streaming = False
    task = session.task
    if task is not None and not task.done():
        task.cancel()
    session.task = None
    if session.h264_encoder is not None:
        encoder = session.h264_encoder
        session.h264_encoder = None
        CAPTURE_POOL.submit(encoder.close)


def start_stream(session: Session) -> None:
    """Start pushing frames, or just let a running loop pick up new parameters.

    ``stream_loop`` re-reads fps / quality / max_width every iteration, so a
    settings change while streaming takes effect without restarting the task.
    """
    session.streaming = True
    if session.task is not None and not session.task.done():
        return
    session.acks = 0
    session.task = asyncio.create_task(stream_loop(session))


async def handle_client(websocket: Any, path: Any = None) -> None:
    session = Session(websocket)
    log.info("client connected: %s", session.peer)

    if TOKEN is None:
        session.authed = True
        await send_json(session, {
            "t": "hello",
            "ok": True,
            "server": "WinRemote/%s" % APP_VERSION,
            "needToken": False,
        })
    else:
        await send_json(session, {
            "t": "hello",
            "ok": False,
            "needToken": True,
            "msg": "send {t:hello, token:...} first",
        })

    try:
        async for raw in websocket:
            if isinstance(raw, (bytes, bytearray)):
                raw = raw.decode("utf-8", "ignore")
            try:
                cmd = json.loads(raw)
            except ValueError:
                await send_json(session, {"t": "err", "msg": "invalid json"})
                continue
            if not isinstance(cmd, dict):
                await send_json(session, {"t": "err", "msg": "invalid message"})
                continue

            kind = str(cmd.get("t", ""))

            if kind == "hello":
                if TOKEN is not None and str(cmd.get("token", "")) != TOKEN:
                    log.warning("auth failed from %s", session.peer)
                    await send_json(session, {"t": "err", "msg": "invalid token"})
                    await websocket.close(code=4001, reason="invalid token")
                    return
                session.authed = True
                info = sys_info()
                info["t"] = "hello"
                info["needToken"] = TOKEN is not None
                await send_json(session, info)
                log.info("client ready: %s", session.peer)
                continue

            if not session.authed:
                await send_json(session, {"t": "err", "msg": "not authenticated"})
                continue

            if kind == "ack":
                await signal_ack(session)
                continue

            if kind == "stream":
                wanted = bool(cmd.get("on", True))
                screen = screen_size()
                if wanted:
                    session.fps = clamp(int(cmd.get("fps", DEFAULT_FPS)), 1, MAX_FPS)
                    session.quality = clamp(int(cmd.get("quality", DEFAULT_QUALITY)), 10, 95)
                    width = int(cmd.get("maxWidth", DEFAULT_MAX_WIDTH))
                    session.max_width = 0 if width <= 0 else clamp(width, 320, 3840)
                    session.ack_mode = bool(cmd.get("ack", False))
                    wanted_codec = str(cmd.get("codec", "jpeg")).strip().lower()
                    if wanted_codec == "h264" and not H264_SUPPORTED:
                        log.warning("client asked for h264 but PyAV/encoder is missing; using jpeg")
                        wanted_codec = "jpeg"
                    if wanted_codec not in ("jpeg", "h264"):
                        wanted_codec = "jpeg"
                    if session.codec != wanted_codec and session.h264_encoder is not None:
                        session.h264_encoder.close()
                        session.h264_encoder = None
                    session.codec = wanted_codec
                    start_stream(session)
                else:
                    stop_stream(session)
                log.info("stream params for %s: %s fps, %s px, q%d, ack=%s, on=%s, codec=%s",
                         session.peer, session.fps,
                         "native" if not session.max_width else session.max_width,
                         session.quality, session.ack_mode, session.streaming, session.codec)
                await send_json(session, {
                    "t": "streamState",
                    "on": session.streaming,
                    "fps": session.fps,
                    "quality": session.quality,
                    "maxWidth": session.max_width,
                    "ackMode": session.ack_mode,
                    "screenW": screen[0],
                    "screenH": screen[1],
                    "codec": session.codec,
                    "backend": CAPTURER.backend,
                })
                continue

            if kind in ("move", "moveto"):
                # high-frequency commands: log at most 1 of every 50
                session._move_log = getattr(session, "_move_log", 0) + 1
                if session._move_log % 50 == 1:
                    log.info("input %s from %s (1/%d logged)", kind, session.peer, session._move_log)
            elif kind in ("click", "scroll", "key", "combo", "text"):
                log.info("input %s from %s: %s", kind, session.peer, raw[:120])

            try:
                reply = dispatch(cmd)
            except Exception as exc:
                log.warning("command %s failed: %s", kind, exc)
                await send_json(session, {"t": "err", "msg": "%s: %s" % (type(exc).__name__, exc)})
                continue

            if reply is not None:
                await send_json(session, reply)

    except Exception as exc:  # connection reset / closed
        log.debug("session ended: %s (%s)", session.peer, exc)
    finally:
        stop_stream(session)
        log.info("client disconnected: %s", session.peer)


def lan_addresses() -> List[str]:
    addresses: List[str] = []
    try:
        hostname = socket.gethostname()
        for item in socket.getaddrinfo(hostname, None, socket.AF_INET):
            addr = item[4][0]
            if addr not in addresses:
                addresses.append(addr)
    except Exception:
        pass
    if not addresses:
        try:
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            probe.connect(("8.8.8.8", 80))
            addresses.append(probe.getsockname()[0])
            probe.close()
        except Exception:
            pass
    return [a for a in addresses if not a.startswith("127.")]


def print_banner(port: int) -> None:
    addresses = lan_addresses()
    width, height = screen_size()
    elevated = is_elevated()
    rule = "=" * 62
    print(rule)
    print("  WinRemote  --  HarmonyOS remote control server   v%s" % APP_VERSION)
    print(rule)
    print("  Status   : LISTENING")
    print("  Screen   : %d x %d" % (width, height))
    print("  Capture  : %s" % CAPTURER.backend)
    if elevated is True:
        print("  Rights   : administrator")
    elif elevated is False:
        print("  Rights   : STANDARD USER  <-- see the warning below")
    else:
        print("  Rights   : unknown")
    print("  Port     : %d" % port)
    if TOKEN:
        print("  Token    : (the value you passed with --token)")
    else:
        print("  Token    : NOT SET -- anyone on this LAN can control this PC")
    if addresses:
        print("  Address  : type ONE of these into the phone app:")
        for addr in addresses:
            print("               %s" % addr)
    else:
        print("  Address  : no LAN IP detected -- run 'ipconfig' to find it")
    print(rule)
    if elevated is False:
        print("  WARNING: not running as administrator.")
        print("  Windows UIPI silently discards injected input while the")
        print("  foreground window belongs to an elevated process, so the")
        print("  remote cursor, clicks and keys freeze as soon as you open")
        print("  Task Manager, Device Manager or any app run as admin.")
        print("  Fix: close this window and restart the server as")
        print("       administrator (right-click -> Run as administrator).")
    elif elevated is None:
        print("  Could not read this process's integrity level. If input")
        print("  stops responding over elevated apps, run as administrator.")
    print("  Allowing this program through Windows Firewall is required")
    print("  the first time you run it.  Press Ctrl+C here to stop.")
    print(rule)
    sys.stdout.flush()


async def run(host: str, port: int) -> None:
    try:
        from websockets.asyncio.server import serve as ws_serve
    except ImportError:
        from websockets.server import serve as ws_serve

    print_banner(port)

    async with ws_serve(handle_client, host, port, max_size=2 ** 22):
        if getattr(sys, "frozen", False):
            asyncio.ensure_future(parent_watchdog())
        await asyncio.Future()


TOKEN: Optional[str] = None


async def parent_watchdog() -> None:
    """Frozen-exe safety net: exit as soon as the bootloader parent is gone.

    PyInstaller onefile runs as parent bootloader + child app process.
    When the console window is closed, the bootloader dies but the child
    can survive holding the port - exactly the "closed but still running"
    zombie users see. Poll the parent handle; if it exits, self-terminate.
    """
    ppid = os.getppid()
    if not ppid:
        return
    import ctypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    SYNCHRONIZE = 0x00100000
    WAIT_OBJECT_0 = 0
    while True:
        handle = kernel32.OpenProcess(SYNCHRONIZE, False, ppid)
        if not handle:
            break
        try:
            if kernel32.WaitForSingleObject(handle, 0) == WAIT_OBJECT_0:
                break
        finally:
            kernel32.CloseHandle(handle)
        await asyncio.sleep(3)
    print("\nConsole closed - exiting.")
    sys.stdout.flush()
    os._exit(0)


def install_exit_handler() -> None:
    """Force-kill the process the moment the console window is closed.

    The WGC capture thread and executor threads are non-daemon; Python's
    graceful shutdown would block on them, leaving a zombie process after
    the user clicks the X button. os._exit() terminates instantly.
    """
    if sys.platform != "win32":
        return
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handler = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.DWORD)

    @handler
    def on_console_event(event: int) -> bool:
        os._exit(0)
        return True

    kernel32.SetConsoleCtrlHandler(on_console_event, True)


def main() -> None:
    global TOKEN
    parser = argparse.ArgumentParser(description="WinRemote LAN server for Windows 11")
    parser.add_argument("--host", default="0.0.0.0", help="bind address (default 0.0.0.0)")
    parser.add_argument("-p", "--port", type=int, default=DEFAULT_PORT, help="listen port (default 8765)")
    parser.add_argument("-t", "--token", default="", help="shared token; empty means no auth")
    parser.add_argument("-q", "--quiet", action="store_true", help="less logging")
    parser.add_argument("-V", "--version", action="version", version="WinRemote %s" % APP_VERSION)
    args = parser.parse_args()

    if args.quiet:
        logging.getLogger().setLevel(logging.WARNING)

    TOKEN = args.token.strip() or None
    install_exit_handler()

    try:
        asyncio.run(run(args.host, args.port))
    except KeyboardInterrupt:
        print("\nstopped")
        os._exit(0)
    except OSError as exc:
        fatal("Cannot listen on port %d: %s\nIs another WinRemote already running?" % (args.port, exc))


if __name__ == "__main__":
    main()
