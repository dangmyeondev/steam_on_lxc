#!/usr/bin/env python3
"""Bridge Sunshine uinput devices to X11 via XTest.

Why: this LXC has no udev, so Xorg never sees Sunshine's virtual
keyboard/mouse (uinput). This daemon reads those evdev nodes directly
and re-injects them into X :0 with XTest. Games read evdev directly,
so they never needed this; the desktop cursor did.

Watches /dev/input by device NAME, so it survives Sunshine restarts
(nodes are recreated) and Xorg restarts (Display reconnect).
"""
import ctypes
import ctypes.util
import glob
import os
import select
import sys
import time

import evdev

EV_KEY, EV_REL, EV_ABS = 0x01, 0x02, 0x03
REL_X, REL_Y, REL_WHEEL, REL_HWHEEL = 0x00, 0x01, 0x08, 0x06
ABS_X, ABS_Y = 0x00, 0x01
BTN_TOUCH = 0x14A
BTN_LEFT, BTN_MIDDLE, BTN_RIGHT = 0x110, 0x112, 0x111
BTN_SIDE, BTN_EXTRA = 0x113, 0x114

NAMES = {
    "Mouse passthrough": "rel",
    "Mouse passthrough (absolute)": "abs",
    "Keyboard passthrough": "kbd",
}
SCREEN_W, SCREEN_H = 1920, 1080
BTN_MAP = {BTN_LEFT: 1, BTN_MIDDLE: 2, BTN_RIGHT: 3, BTN_SIDE: 8, BTN_EXTRA: 9}


class XTest:
    def __init__(self):
        self.dpy = None
        libx11 = ctypes.CDLL(ctypes.util.find_library("X11"))
        libxtst = ctypes.CDLL(ctypes.util.find_library("Xtst"))
        libx11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        libx11.XOpenDisplay.restype = ctypes.c_void_p
        libx11.XFlush.argtypes = [ctypes.c_void_p]
        libx11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        libxtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                              ctypes.c_int, ctypes.c_ulong]
        libxtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                                 ctypes.c_int, ctypes.c_ulong]
        libxtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                 ctypes.c_int, ctypes.c_int,
                                                 ctypes.c_ulong]
        libxtst.XTestFakeRelativeMotionEvent.argtypes = [ctypes.c_void_p,
                                                         ctypes.c_int,
                                                         ctypes.c_int,
                                                         ctypes.c_ulong]
        self._x11, self._xtst = libx11, libxtst

    def ensure(self):
        if self.dpy:
            return True
        try:
            self.dpy = self._x11.XOpenDisplay(None)
        except Exception:
            self.dpy = None
        return bool(self.dpy)

    def drop(self):
        if self.dpy:
            try:
                self._x11.XCloseDisplay(self.dpy)
            except Exception:
                pass
            self.dpy = None

    def _call(self, fn, *args):
        if not self.ensure():
            return False
        try:
            fn(self.dpy, *args)
            self._x11.XFlush(self.dpy)
            return True
        except Exception:
            self.drop()
            return False

    def key(self, code, press):
        return self._call(self._xtst.XTestFakeKeyEvent, code + 8, int(press), 0)

    def button(self, btn, press):
        return self._call(self._xtst.XTestFakeButtonEvent, btn, int(press), 0)

    def motion_abs(self, x, y):
        return self._call(self._xtst.XTestFakeMotionEvent, -1, x, y, 0)

    def motion_rel(self, dx, dy):
        return self._call(self._xtst.XTestFakeRelativeMotionEvent, dx, dy, 0)


def find_nodes():
    """Map role -> /dev/input/eventN by device name."""
    found = {}
    for path in glob.glob("/dev/input/event*"):
        try:
            with open(os.path.join("/sys/class/input",
                                   os.path.basename(path),
                                   "device/name")) as f:
                name = f.read().strip()
        except OSError:
            continue
        if name in NAMES:
            found[NAMES[name]] = path
    return found


def scale(val, info, size):
    span = (info.max - info.min) or 1
    val = min(max(val, info.min), info.max)
    return int((val - info.min) * (size - 1) / span)


def main():
    xt = XTest()
    devs = {}  # role -> evdev.InputDevice
    absinfo = {}
    print("bridge starting, waiting for Sunshine uinput devices...", flush=True)
    while True:
        try:
            for role, path in find_nodes().items():
                if role in devs:
                    continue
                try:
                    dev = evdev.InputDevice(path)
                    devs[role] = dev
                    if role == "abs":
                        absinfo["x"] = dev.absinfo(ABS_X)
                        absinfo["y"] = dev.absinfo(ABS_Y)
                    print(f"attached {role}: {path} ({dev.name})", flush=True)
                except OSError as e:
                    print(f"cannot open {path}: {e}", flush=True)
            if not devs:
                time.sleep(2)
                continue
            r, _, _ = select.select([d.fd for d in devs.values()], [], [], 5)
            for role, dev in list(devs.items()):
                if dev.fd not in r:
                    continue
                try:
                    while True:
                        ev = dev.read_one()
                        if ev is None:
                            break
                        handle(xt, role, ev, absinfo)
                except OSError:
                    print(f"lost {role}, rescanning...", flush=True)
                    devs.pop(role, None)
        except Exception as e:
            print(f"loop error: {e}", flush=True)
            time.sleep(2)


def handle(xt, role, ev, absinfo):
    if ev.type == EV_KEY:
        if role == "kbd":
            if ev.value in (0, 1):
                xt.key(ev.code, ev.value == 1)
            elif ev.value == 2:
                xt.key(ev.code, True)
        elif role == "abs" and ev.code == BTN_TOUCH:
            xt.button(1, ev.value != 0)
        elif ev.code in BTN_MAP and role != "kbd":
            if ev.value in (0, 1):
                xt.button(BTN_MAP[ev.code], ev.value == 1)
    elif ev.type == EV_REL and role == "rel":
        # Emit each axis immediately. (Previous X-buffer-until-Y logic dropped
        # X-only deltas, making relative-mouse clients feel dead.)
        if ev.code == REL_X and ev.value:
            xt.motion_rel(ev.value, 0)
        elif ev.code == REL_Y and ev.value:
            xt.motion_rel(0, ev.value)
        elif ev.code == REL_WHEEL and ev.value:
            xt.button(4 if ev.value > 0 else 5, True)
            xt.button(4 if ev.value > 0 else 5, False)
        elif ev.code == REL_HWHEEL and ev.value:
            xt.button(6 if ev.value > 0 else 7, True)
            xt.button(6 if ev.value > 0 else 7, False)
    elif ev.type == EV_ABS and role == "abs":
        if ev.code in (ABS_X, ABS_Y) and "x" in absinfo:
            handle.abs_pos = getattr(handle, "abs_pos", [0, 0])
            if ev.code == ABS_X:
                handle.abs_pos[0] = scale(ev.value, absinfo["x"], SCREEN_W)
            else:
                handle.abs_pos[1] = scale(ev.value, absinfo["y"], SCREEN_H)
            xt.motion_abs(*handle.abs_pos)


if __name__ == "__main__":
    main()
