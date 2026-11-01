"""Trade session: handshake, then exchange one Pokemon each way with ack/retry."""
from . import protocol as p

VERSION = 1


class TradeError(Exception):
    pass


class TradeSession:
    def __init__(self, transport):
        self.t = transport

    def _send(self, ftype, payload=b""):
        self.t.write(p.encode(ftype, payload))

    def _recv(self):
        while True:
            try:
                return p.read_frame(self.t.read)
            except p.FrameError:
                self._send(p.NAK)

    def _expect(self, want):
        ftype, payload = self._recv()
        if ftype != want:
            raise TradeError(f"unexpected frame type {ftype}")
        return payload

    def handshake(self):
        self._send(p.HELLO, bytes([VERSION]))
        if self._expect(p.HELLO) != bytes([VERSION]):
            raise TradeError("protocol version mismatch")

    def trade(self, pokemon: bytes) -> bytes:
        """Send our Pokemon and return the peer's. Both sides call this concurrently."""
        if len(pokemon) != p.POKEMON_SIZE:
            raise TradeError(f"Pokemon data must be {p.POKEMON_SIZE} bytes")
        self.handshake()
        self._send(p.POKEMON, pokemon)
        theirs = self._expect(p.POKEMON)
        if len(theirs) != p.POKEMON_SIZE:
            raise TradeError("invalid Pokemon from peer")
        self._send(p.ACK)
        self._expect(p.ACK)
        self._send(p.BYE)
        return theirs
