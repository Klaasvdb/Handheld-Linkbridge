# Handheld LinkBridge

Trade and battle Pokémon between retro handhelds (starting with the R36S) over
a "virtual link cable": an IP connection between two devices, ideally a single
USB-C cable, carried into the emulated Game Boy link port by the libretro
Gambatte core. No ROM patches, no new emulator.

**Status:** Phase 0 (feasibility). Nothing has been validated on hardware yet.
See [docs/design.md](docs/design.md) for the full design and roadmap.

First milestone: two R36S units trading a Pokémon in Pokémon Red over a cable.

## What is in here

| Path | What |
|---|---|
| [`docs/design.md`](docs/design.md) | Design, transport options, roadmap, risks |
| [`docs/compatibility.md`](docs/compatibility.md) | Device × firmware × transport × core matrix |
| [`doctor/linkbridge-doctor.sh`](doctor/linkbridge-doctor.sh) | Phase 0 checks to run on each handheld |
| [`config/linkbridge-config.sh`](config/linkbridge-config.sh) | Writes Gambatte link core options (server/client) |
| [`tests/pc-loopback.sh`](tests/pc-loopback.sh) | Two RetroArch instances linked over localhost on a PC |

## Help out: run the doctor on your handheld

Copy `doctor/linkbridge-doctor.sh` to the device (for example to the
`roms` SD card partition), then over SSH or a terminal:

```bash
sh linkbridge-doctor.sh
```

The script is read-only: it does not load modules or change any settings. It
prints a report and saves it as `linkbridge-doctor-<host>-<date>.txt`. Send that
file so it can be added to [docs/compatibility.md](docs/compatibility.md).

Optional flags:

- `--peer 10.77.0.2` pings the other handheld once you have a cable link.
- `--load-modules` (as root) really loads the test drivers instead of only a dry run.
- `--core /path/to/gambatte_libretro.so` if the core lives in an unusual place.

## Try a trade on a PC first

You need RetroArch with the Gambatte core (from the Online Updater), your own
Pokémon Red/Blue ROM, and two saved games (`.sav` or `.srm`).

```bash
tests/pc-loopback.sh --rom pokered.gb --save-a player1.sav --save-b player2.sav
```

Instance A runs as link server, instance B as client on `127.0.0.1:56400`.
Your original saves are copied, never modified; the results land in the
session directory the script prints. Use `--dry-run` to see the generated
configs without starting anything.

## Rules

- No ROMs, BIOS files or patched ROMs in this repository. Bring your own legally obtained games.
- No cheat or save-editing tools.
- Both players need the same language version of the game; mixing languages corrupts trades.
- Always keep a backup of your save before a link session.

## License

MIT, see [LICENSE](LICENSE).
