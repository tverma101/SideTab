#!/usr/bin/env python3
"""ss_forwarder.py — relay tunnel-side ports to the SideScreen server loopback.

Video:  10.77.0.1:54326 -> 127.0.0.1:54321  (stream + in-band ping/pong)
Control: 10.77.0.1:54327 -> 127.0.0.1:54322  (out-of-band ping/pong channel)

User-space, no root (lo0 pin already in place). One-cable path for the
SideScreen tablet app. TCP_NODELAY on every socket: small control packets
(pongs) must never wait behind video segments.
"""
import socket
import threading

RELAYS = [
    (("10.77.0.1", 54326), ("127.0.0.1", 54321)),  # video
    (("10.77.0.1", 54327), ("127.0.0.1", 54322)),  # control
]


def pipe(src, dst):
    try:
        while True:
            d = src.recv(65536)
            if not d:
                break
            dst.sendall(d)
    except Exception:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def handle(c, target):
    try:
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        t = socket.create_connection(target, timeout=5)
        t.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        t.settimeout(None)  # connect timeout must not linger: recv() would
                            # raise after 5s idle and half-close the relay
                            # (killed the idle control channel exactly at 5s)
    except Exception as e:
        print(f"fwd: target connect failed {target}: {e}", flush=True)
        c.close()
        return
    print(f"fwd: relay {c.getpeername()} -> {target}", flush=True)
    threading.Thread(target=pipe, args=(c, t), daemon=True).start()
    threading.Thread(target=pipe, args=(t, c), daemon=True).start()


def serve(listen, target):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(listen)
    s.listen(8)
    print(f"ss_forwarder: listening {listen} -> {target}", flush=True)
    while True:
        c, a = s.accept()
        threading.Thread(target=handle, args=(c, target), daemon=True).start()


for listen, target in RELAYS:
    threading.Thread(target=serve, args=(listen, target), daemon=True).start()

threading.Event().wait()
