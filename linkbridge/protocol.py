"""Framing: MAGIC(2) | type(1) | length(2, BE) | payload | CRC16-CCITT(2, BE over type..payload)."""
import struct

MAGIC = b"\xa5\x5a"
HELLO, POKEMON, ACK, NAK, BYE = 1, 2, 3, 4, 5
MAX_PAYLOAD = 1024
POKEMON_SIZE = 100  # Gen 3 party Pokemon structure (GBA games)


class FrameError(Exception):
    pass


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(ftype: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise FrameError("payload too large")
    body = struct.pack(">BH", ftype, len(payload)) + payload
    return MAGIC + body + struct.pack(">H", crc16(body))


def read_frame(read) -> tuple:
    """Read one frame using read(n)->bytes (must return exactly n bytes or raise EOFError)."""
    window = b""
    while window != MAGIC:  # resynchronise on magic
        window = (window + read(1))[-2:]
    ftype, length = struct.unpack(">BH", read(3))
    if length > MAX_PAYLOAD:
        raise FrameError("payload too large")
    payload = read(length)
    (crc,) = struct.unpack(">H", read(2))
    if crc != crc16(struct.pack(">BH", ftype, length) + payload):
        raise FrameError("bad CRC")
    return ftype, payload
