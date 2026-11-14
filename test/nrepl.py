#!/usr/bin/env python3
"""Minimal nREPL client (bencode over TCP) for the REPL tests.

    nrepl.py PORT CODE [NS] evaluate CODE (in namespace NS, as an editor
                            does for the current buffer), print the value
                            (or the error), exit 1 on an exception

Speaks the same protocol as CIDER / Calva, against `jolt nrepl-server` or a
server an app started with jolt.nrepl/start.
"""
import socket
import sys
import uuid


def enc(x):
    if isinstance(x, int):
        return b"i%de" % x
    if isinstance(x, str):
        x = x.encode()
    if isinstance(x, bytes):
        return b"%d:%s" % (len(x), x)
    if isinstance(x, list):
        return b"l" + b"".join(enc(i) for i in x) + b"e"
    if isinstance(x, dict):
        return b"d" + b"".join(enc(k) + enc(v) for k, v in sorted(x.items())) + b"e"
    raise TypeError(type(x))


class Reader:
    def __init__(self, sock):
        self.sock, self.buf = sock, b""

    def need(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("connection closed")
            self.buf += chunk

    def take(self, n):
        self.need(n)
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def peek(self):
        self.need(1)
        return self.buf[:1]

    def read(self):
        c = self.peek()
        if c == b"i":
            self.take(1)
            num = b""
            while self.peek() != b"e":
                num += self.take(1)
            self.take(1)
            return int(num)
        if c == b"l":
            self.take(1)
            out = []
            while self.peek() != b"e":
                out.append(self.read())
            self.take(1)
            return out
        if c == b"d":
            self.take(1)
            out = {}
            while self.peek() != b"e":
                k = self.read()
                out[k] = self.read()
            self.take(1)
            return out
        n = b""
        while self.peek() != b":":
            n += self.take(1)
        self.take(1)
        return self.take(int(n)).decode("utf-8", "replace")


def evaluate(port, code, ns=None, timeout=60):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    r = Reader(s)
    mid = str(uuid.uuid4())
    req = {"op": "eval", "code": code, "id": mid}
    if ns:
        req["ns"] = ns
    s.sendall(enc(req))
    value, out, err, ex = None, "", "", None
    while True:
        msg = r.read()
        if msg.get("id") not in (mid, None):
            continue
        value = msg.get("value", value)
        out += msg.get("out", "")
        err += msg.get("err", "")
        ex = msg.get("ex", ex)
        if "done" in msg.get("status", []):
            break
    s.close()
    return value, out, err, ex


if __name__ == "__main__":
    port, code = int(sys.argv[1]), sys.argv[2]
    ns = sys.argv[3] if len(sys.argv) > 3 else None
    value, out, err, ex = evaluate(port, code, ns)
    if out:
        sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    if ex or err.strip():
        print("ERROR:", ex or err.strip())
        sys.exit(1)
    print(value)
