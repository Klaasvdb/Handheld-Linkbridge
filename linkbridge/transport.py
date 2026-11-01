"""Byte transports: a serial device (USB-C gadget/host port), or an in-memory pair for tests."""
import os
import queue
import termios
import tty


class Transport:
    def read(self, n: int) -> bytes:
        raise NotImplementedError

    def write(self, data: bytes) -> None:
        raise NotImplementedError

    def close(self) -> None:
        pass


class SerialTransport(Transport):
    """Raw tty, e.g. /dev/ttyGS0 (USB gadget side) or /dev/ttyACM0 (USB host side)."""

    def __init__(self, path: str):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        tty.setraw(self.fd)
        attrs = termios.tcgetattr(self.fd)
        attrs[6][termios.VMIN], attrs[6][termios.VTIME] = 1, 0
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)

    def read(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = os.read(self.fd, n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf

    def write(self, data: bytes) -> None:
        while data:
            data = data[os.write(self.fd, data):]

    def close(self) -> None:
        os.close(self.fd)


class LoopbackTransport(Transport):
    def __init__(self, rx, tx):
        self._rx, self._tx = rx, tx

    @classmethod
    def pair(cls):
        a, b = queue.Queue(), queue.Queue()
        return cls(a, b), cls(b, a)

    def read(self, n: int) -> bytes:
        try:
            return bytes(self._rx.get(timeout=5) for _ in range(n))
        except queue.Empty:
            raise EOFError

    def write(self, data: bytes) -> None:
        for b in data:
            self._tx.put(b)
