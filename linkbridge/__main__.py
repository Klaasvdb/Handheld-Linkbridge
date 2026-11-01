import argparse
import sys

from .trade import TradeSession
from .transport import SerialTransport


def main(argv=None):
    ap = argparse.ArgumentParser(description="Trade a Pokemon over a USB-C link (R36S).")
    ap.add_argument("device", help="serial device, e.g. /dev/ttyGS0 or /dev/ttyACM0")
    ap.add_argument("send", help="file with the 100-byte Pokemon to send")
    ap.add_argument("receive", help="file to write the received Pokemon to")
    a = ap.parse_args(argv)
    t = SerialTransport(a.device)
    try:
        with open(a.send, "rb") as f:
            theirs = TradeSession(t).trade(f.read())
    finally:
        t.close()
    with open(a.receive, "wb") as f:
        f.write(theirs)
    print("Trade complete", file=sys.stderr)


if __name__ == "__main__":
    main()
