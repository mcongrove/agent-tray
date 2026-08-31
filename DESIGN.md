# Design System

## Direction

Always-on right-edge notch, dark like a hardware cutout. The physical scene is a developer working full-screen with the notch parked in peripheral vision; neon green is reserved for live usage. The notch stays dark in both system appearances.

## Color

Strategy: restrained, hardware-dark.

- Notch fill: `oklch(0.145 0.004 260)`
- Accent: `oklch(0.88 0.21 140)`, neon green for healthy usage
- Warning: `oklch(0.88 0.16 115)`
- Danger: `oklch(0.68 0.20 25)`
- Ink: white
- Muted: white at 48–72% opacity
- Ring track: white at 14%

## Typography

SF Pro. Percents on the notch use rounded semibold at 12pt with monospaced digits. Tooltip titles are 13pt semibold. Reset captions are 11pt.

## Layout

- Notch width: 76 points, flush to the right display edge
- Tooltip width: 248 points, to the left of the hovered meter
- Four-point spacing scale: 4, 8, 12, 16, 24
- Settings control sits below the notch and appears only when the pointer enters the bottom of the column

## Components

- Notch meter: provider symbol and circular progress ring. Percents live in the tooltip only.
- Usage tooltip: title, one row per quota window (label, reset time, bar, used amount). No activity metrics.
- Settings: 36-point circle with gear; no-op until wired

## Motion

150–180 ms ease-out for tooltip and settings reveal. Disable nonessential motion when Reduce Motion is enabled. Never animate usage rings from a fabricated zero state.
