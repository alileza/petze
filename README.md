# petze

A tiny macOS menu bar app that shows your laptop's health as thin lines drawn
on the edge of your screen. Each line's length is the metric's level; its
color tells you how healthy it is. Lines stack from the screen edge inward:

1. **Battery** (outermost) — length = charge level
2. **CPU load** — length = total CPU usage
3. **Memory used** — length = fraction of RAM in use (active + wired + compressed)
4. **Network in / out** — log-scaled throughput (each quarter of the line is
   one decade, 10 KB/s → 100 MB/s)

## Display modes

**Automatic** (default) shows only what matters right now — on a quiet machine
that's a single memory line. Other lines appear when they have something to
say and retract when the moment passes:

- **Battery** appears while charging, or when discharging below ~40%
- **CPU** appears when load crosses 60%, retracts once it calms below 45%
- **Network** lines appear above ~500 KB/s sustained, retract below 100 KB/s

Entry and exit thresholds differ (hysteresis) so lines don't flicker at the
boundary.

**Manual** lets you pin exactly the lines you want, from the menu bar icon.

## Colors

Battery color = what the battery is doing:

| Color  | Meaning                          |
|--------|----------------------------------|
| Green  | Charging                         |
| Blue   | On AC, not charging (full/held)  |
| Yellow | Discharging                      |
| Red    | Discharging, 20% or below        |

CPU and memory color = how loaded they are: green below 60%, yellow below
85%, red above. Network lines have fixed identities: teal = inbound,
purple = outbound.

## Positions

Click the menu bar icon (⚡/− plus percentage) to choose where the lines live:

- **Top edge** — lines grow left → right along the top of the screen
- **Bottom edge** — same, along the bottom
- **Around screen** — lines travel clockwise around the screen border starting
  at the top-left corner, nested one inside the other; a full metric draws a
  complete frame

Mode, position, and line toggles are remembered across launches. The overlay
is click-through and appears on every connected display and every Space.

## Build & run

```bash
swift build -c release
.build/release/petze
```

Or bundle it as an app (so you can put it in Applications / Login Items):

```bash
./make-app.sh
open petze.app
```

Quit from the menu bar icon → "Quit petze".
