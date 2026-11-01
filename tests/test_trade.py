import threading
import unittest

from linkbridge import protocol as p
from linkbridge.trade import TradeSession
from linkbridge.transport import LoopbackTransport


class Tests(unittest.TestCase):
    def test_roundtrip_and_resync(self):
        data = p.encode(p.POKEMON, b"x" * 100)
        pos = iter(b"junk" + data)
        self.assertEqual(p.read_frame(lambda n: bytes(next(pos) for _ in range(n))), (p.POKEMON, b"x" * 100))

    def test_bad_crc(self):
        data = bytearray(p.encode(p.ACK))
        data[-1] ^= 1
        pos = iter(bytes(data))
        with self.assertRaises(p.FrameError):
            p.read_frame(lambda n: bytes(next(pos) for _ in range(n)))

    def test_trade(self):
        a, b = LoopbackTransport.pair()
        pa, pb = b"A" * 100, b"B" * 100
        res = {}
        th = threading.Thread(target=lambda: res.update(b=TradeSession(b).trade(pb)))
        th.start()
        res["a"] = TradeSession(a).trade(pa)
        th.join()
        self.assertEqual(res, {"a": pb, "b": pa})


if __name__ == "__main__":
    unittest.main()
