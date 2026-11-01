# Handheld-Linkbridge
Link layer for handhelds (starting with the R36S) to trade Pokemon between GBA games
over a USB-C to USB-C cable.

- `linkbridge/protocol.py`: CRC-protected framing
- `linkbridge/transport.py`: serial (`/dev/ttyGS0` / `/dev/ttyACM0`) and loopback transports
- `linkbridge/trade.py`: handshake + Pokemon exchange (100-byte Gen 3 structure)

Run on both devices: `python -m linkbridge /dev/ttyACM0 send.bin received.bin`

Tests: `python -m unittest discover tests`
