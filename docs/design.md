# Handheld LinkBridge: Pokémon trading between emulator handhelds

Status: design v0.2 (not yet validated on hardware)
Repository name: `handheld-linkbridge`

## 1. Goal

Let two or more retro handhelds (starting with the R36S) trade and battle Pokémon over a "virtual link cable", preferably a plain USB-C cable between the two devices, without modifying the ROMs. The long-term ambition is breadth: many handhelds, many emulator cores, many Pokémon generations.

First milestone: **two R36S units trading a Pokémon in Pokémon Red over a USB-C cable.**

Non-goals:
- No ROMs, BIOS files or patched ROMs in the repository. Users supply their own legally obtained games.
- No cheat or hacking tools (no Pokémon generation or save editing for advantage).
- No new emulator. We build on existing cores.

## 2. Core insight: the ROM is not the problem

A Pokémon ROM knows nothing about USB-C. The game talks to the serial link port of an emulated Game Boy. Trading works as soon as the emulator connects that port to something on the other side. The work therefore lives in three layers, none of which is the ROM:

1. **Physical/IP link** between the two handhelds (USB-C cable, Wi-Fi, adapters).
2. **Emulator link support** that carries the Game Boy serial port over that IP link.
3. **Glue**: configuration, launchers and diagnostics so it is a two-button experience on the device.

## 3. What already exists (Gen 1 and 2)

The libretro **Gambatte** core already supports Game Boy link cable play over a network, with a server/client mode and a configurable port. Relevant core options:

| Option | Server (device A) | Client (device B) |
|---|---|---|
| `gambatte_gb_link_mode` | `Network Server` | `Network Client` |
| `gambatte_gb_link_network_port` | `56400` | `56400` |
| server IP options | n/a | IP address of device A |

The server starts the game first, then the client joins. Note: the server IP option names differ between Gambatte versions (older builds split the address into four octets, newer builds use twelve single-digit fields). Our tooling must detect which variant is installed.

Network support in Gambatte is a compile-time flag (`HAVE_NETWORK`), and some builds ship with it disabled. Checking this on the R36S firmware is task 1 of Phase 0.

Other cores, for reference:
- **TGB Dual** and **SameBoy** emulate a link cable by running two games side by side on one device. Useful for testing the trade flow on a single R36S or PC, not for two devices.
- **DoubleCherryGB** offers multi-instance linking on one device.

Consequence: for Gen 1 and 2 we likely do **not** need to patch an emulator. The real engineering problem is giving two handhelds a reliable, low-latency IP connection over USB-C, and making the setup painless.

## 4. Hardware: the R36S

- SoC: Rockchip RK3326 (ARM64), Linux-based firmware (ArkOS, dArkOS, ROCKNIX and others).
- Two USB-C ports: one for power, one for data (OTG). The data port is our target.
- Most R36S variants have no built-in Wi-Fi.

Key unknown: can the data port act as a **USB device (gadget)** and not only as a host? This decides which transport option below works.

## 5. Transport options (how to get IP between two handhelds)

All options end in the same result: device A and device B each have an IP address on a private point-to-point network, and Gambatte connects over it.

**Option A: USB gadget Ethernet (one cable, cheapest)**
Device A puts its data port in peripheral mode and exposes a USB network interface (CDC NCM or ECM via configfs). Device B sees it as a USB Ethernet adapter. Requirements: OTG controller with device-mode support, kernel built with USB gadget and configfs, and a correctly wired role/ID line on the port. Cable: USB-C to USB-C data cable (possibly with an OTG adapter, depending on role detection).

**Option B: USB host-to-host bridge cable (most likely to work)**
A "USB data link" or "bridge" cable contains a chip (for example Prolific PL25A1/PL27A1) that appears as a network device to both sides. Both handhelds stay in normal host mode, so no gadget support is needed. Requirement: the matching kernel driver (`plusb` for Prolific bridges) on the firmware. Cable: bridge cable plus USB-A to USB-C OTG adapters.

**Option C: two USB Ethernet adapters back to back**
Each handheld gets a cheap USB Ethernet dongle via OTG; the dongles are joined by a regular Ethernet cable. Very robust, common drivers (`r8152`, `ax88179_178a`), but bulkier.

**Option D: Wi-Fi**
A USB Wi-Fi dongle on each handheld, connected to a shared network or a phone hotspot. Easiest to understand, worst latency and stability, but also the path to online play and other handhelds.

Order of attempts: B and C in Phase 0 (fast proof), then A as the polished "one cable" goal, D for broader reach.

## 6. Architecture

```
[Pokémon Red] -> [Gambatte core] -- TCP :56400 --> [IP link] --> [Gambatte core] -> [Pokémon Red]
                                                       ^
                          usb0 / eth0 / wlan0 configured by linkbridge
```

Components:
1. **`linkbridge-net`**: shell scripts (later possibly a small daemon) that detect the available transport, bring up the interface and assign fixed addresses (device A `10.77.0.1`, device B `10.77.0.2`). Fixed addresses avoid DHCP and make Gambatte configuration static.
2. **`linkbridge-config`**: writes the correct Gambatte core options for the server or client role, handling both option-name variants. Uses per-game override files so normal single-player settings are untouched.
3. **Launcher entries**: two items in the frontend menu, "Host link session" and "Join link session", that set up networking, write the config and start the game.
4. **Diagnostics**: `linkbridge-doctor` checks USB mode, kernel modules, interface state, ping latency, and whether Gambatte was built with network support.
5. **Save safety**: automatic backup of the `.srm` save file before every link session.

## 7. Pokémon Red specifics (Phase 1 target)

- Link features: trading and battling at the Cable Club (Pokémon Center, second floor). Both games must be saved before entering.
- Compatible partners: Red, Blue and Yellow trade with each other. Same-language versions are required; mixing languages (for example a Japanese and a European cartridge) corrupts trades.
- Gen 1 link timing is tolerant of latency, so it is the right first target.
- Trade evolutions (Kadabra, Machoke, Graveler, Haunter) are a good end-to-end test because the evolution only triggers if the trade completed correctly.
- Later: Gen 2 (Gold, Silver, Crystal) through the same core, including the Time Capsule to trade with Gen 1.

## 8. Roadmap

**Phase 0: feasibility (one weekend)**
- Identify firmware and kernel on the R36S units (`uname -a`, firmware name and version).
- Check whether the installed Gambatte core has network link options.
- Check kernel support: `ls /sys/class/udc` (gadget capable?), `modprobe` tests for `plusb`, `r8152`, `cdc_ncm`, `usb_f_ncm`.
- Proof on PC: two RetroArch instances with Gambatte over localhost, Pokémon Red trade.

**Phase 1: Pokémon Red over a cable**
- Get IP between two R36S units with option B or C.
- Manual Gambatte server/client config, complete one trade and one battle.
- Write down every step in `docs/phase1-log.md`.

**Phase 2: one-cable experience**
- Try option A (gadget Ethernet) on the data port.
- Package `linkbridge-net`, `linkbridge-config` and the launcher entries.

**Phase 3: Gen 2 and more devices**
- Gold, Silver, Crystal, Time Capsule.
- Other RK3326/RK3566 handhelds and firmwares (ROCKNIX, muOS, Batocera, Android RetroArch).

**Phase 4: Gen 3 (GBA)**
- Investigate link support in mGBA and other GBA cores. GBA link timing is much stricter; this phase may require core work.

**Phase 5: Gen 4 and 5 (DS)**
- DS games trade over wireless/online, not a cable. Investigate local wireless in melonDS and community replacements for the defunct Nintendo Wi-Fi Connection service.

## 9. Repository layout

```
handheld-linkbridge/
  README.md
  LICENSE
  docs/
    design.md
    compatibility.md     device x firmware x transport x core matrix
    phase1-log.md
  net/                   linkbridge-net: interface setup per transport
  config/                linkbridge-config: Gambatte option writers
  launchers/             frontend menu entries per firmware
  doctor/                linkbridge-doctor diagnostics
  backup/                save backup helpers
  tests/                 PC-based loopback and latency tests
```

## 10. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Firmware Gambatte built without network | No link at all | Build our own Gambatte core for aarch64 with `HAVE_NETWORK=1` |
| Data port is host-only | Option A fails | Options B and C work in host mode |
| Missing kernel drivers | B, C or D fail | Ship modules where possible, or document a firmware that has them |
| Connection drop during trade | Lost or duplicated Pokémon, broken save | Automatic save backup before every session |
| Different firmwares per friend | Inconsistent behaviour | Compatibility matrix and `linkbridge-doctor` |

## 11. Open questions

1. Which firmware and version run on each R36S in the group? Are they all the same?
2. Is everyone using the same language version of Pokémon Red/Blue?
3. Who in the group can test hardware (two devices side by side)?
4. Private tool for the group or public open-source project? This affects the license choice and documentation effort.

## 12. First tasks for Claude Code

1. Create the repository with this document in `docs/design.md`, a README and a license.
2. Write `doctor/linkbridge-doctor.sh` with the Phase 0 checks, so friends can run it and paste the output.
3. Write a PC test script that launches two RetroArch instances with Gambatte as server and client on localhost.
4. Set up `docs/compatibility.md` as an empty matrix to fill in from doctor reports.
