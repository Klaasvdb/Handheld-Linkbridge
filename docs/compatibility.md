# Compatibility matrix

Filled in from `linkbridge-doctor` reports and real cable tests. One row per
device + firmware combination. Please add a row (or update one) via a pull
request or by pasting your doctor report in an issue.

Legend: ✅ works (tested with a cable) · 🟡 software looks OK, not yet tested ·
❌ does not work · ❔ unknown / not checked

Transports (see [design.md](design.md) section 5):
A = USB gadget Ethernet, B = USB bridge cable (`plusb`), C = USB Ethernet
dongles back to back, D = Wi-Fi.

## Devices and transports

| Device | Firmware + version | Kernel (`uname -r`) | Gambatte network | IP variant | UDC (A) | A | B | C | D | Tested by | Report date | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | | | | |

Column notes:
- **Gambatte network**: `Network link options` line in the doctor report (PRESENT / ABSENT / NOT FOUND).
- **IP variant**: `twelve single digits` or `four octets` (server IP option naming).
- **UDC (A)**: contents of `/sys/class/udc`, empty means no gadget mode.

## Link sessions

Real tests between two devices. Fill in after a trade or battle attempt.

| Device A (server) | Device B (client) | Transport | Game(s) + language | Ping avg (ms) | Trade | Battle | Date | Notes |
|---|---|---|---|---|---|---|---|---|
| | | | | | | | | |

## Cables and adapters

Known working (or failing) hardware, so others can buy the right thing.

| Type | Product / chip | Driver | Result | Notes |
|---|---|---|---|---|
| | | | | |
