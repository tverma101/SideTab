#!/usr/bin/env python3
"""E3 shell relay — bridges root_bridge (127.0.0.1:7777) to the tablet's PipeClient
listener through the adb SHELL service.

WHY: adb's reverse/forward stream machinery is broken on this Samsung UsbFfs transport
(payload corruption/drops, verified 2026-08-13), while the shell service carries bulk
data byte-exact. So the pipe rides `adb shell "nc 127.0.0.1 7777"`:
    tablet app (listener, 127.0.0.1:7777) <-> device nc <-> adb shell stream
        <-> this relay (userspace) <-> root_bridge (accepts on 127.0.0.1:7777)

No root, no bridge changes: the bridge keeps its accept loop and single-pump
generations; this relay is just the newest client. It reconnects forever.
"""
import os
import select
import socket
import subprocess
import sys
import threading
import time

BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 7777
ADB = "adb"
DEV_NC = "sh -c 'dalvikvm -cp /data/local/tmp/ncnd.jar NcNd 127.0.0.1 7777 2>/sdcard/nc_err; echo rc=$? > /sdcard/nc_exit'"


def log(m):
    print(f"[relay] {m}", flush=True)


def pump(rfd, wfd, name, counters):
    """One direction of the pipe; returns on EOF/error. counters = [bytes_moved]."""
    try:
        while True:
            r, _, _ = select.select([rfd], [], [], 5)
            if not r:
                continue
            data = os.read(rfd, 32768)
            if not data:
                return
            os.write(wfd, data)
            counters[0] += len(data)
    except OSError as e:
        log(f"{name}: {e}")


def main():
    while True:
        b = None
        proc = None
        c_bs = [0]  # bridge -> shell bytes
        c_sb = [0]  # shell -> bridge bytes
        try:
            # 1. dial the bridge (it accepts any client; a new generation retires the old)
            b = socket.socket()
            b.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            b.settimeout(10)
            b.connect((BRIDGE_HOST, BRIDGE_PORT))
            b.settimeout(None)
            log("bridge connected")

            # 2. spawn the shell stream -> the app's listener on the device
            proc = subprocess.Popen(
                [ADB, "shell", DEV_NC],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL)
            log("adb shell nc spawned")

            bfd, wfd, rfd = b.fileno(), proc.stdin.fileno(), proc.stdout.fileno()
            t1 = threading.Thread(target=pump, args=(bfd, wfd, "bridge->shell", c_bs), daemon=True)
            t2 = threading.Thread(target=pump, args=(rfd, bfd, "shell->bridge", c_sb), daemon=True)
            t1.start()
            t2.start()
            while t1.is_alive() and t2.is_alive():
                time.sleep(1)
                log(f"counters: bridge->shell {c_bs[0]} B | shell->bridge {c_sb[0]} B | alive={t1.is_alive()}/{t2.is_alive()}")
            # One direction can exit while the other is still blocked in select/read.
            # Tear down both endpoints before joining so the outer loop can reconnect.
            try:
                b.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            if proc.poll() is None:
                proc.kill()
            t1.join(timeout=2)
            t2.join(timeout=2)
            log(f"chain ended: bridge->shell {c_bs[0]} B | shell->bridge {c_sb[0]} B")
        except Exception as e:
            log(f"chain error: {e}")
        finally:
            if b is not None:
                try:
                    b.close()
                except OSError:
                    pass
            if proc is not None and proc.poll() is None:
                try:
                    proc.kill()
                except OSError:
                    pass
        time.sleep(1)


if __name__ == "__main__":
    main()
