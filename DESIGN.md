# Design System

## Direction

Native macOS utility with the density of a status inspector: compact rows, clear dividers, quiet materials, and color reserved for live state and usage progress. The physical scene is a developer glancing at the menu bar during a long work session in changing ambient light, so the interface follows the system appearance.

## Color

Strategy: restrained. Runtime surfaces use semantic macOS colors so light, dark, increased-contrast, and vibrancy settings remain correct.

- Primary: `oklch(0.688 0.133 35.8)`, warm coral used sparingly for Agent Tray identity and warnings
- Accent: `oklch(0.630 0.145 250)`, cool blue for healthy usage progress
- Light background: `oklch(1 0 0)`
- Light surface: `oklch(0.965 0 0)`
- Light ink: `oklch(0.210 0.006 35.8)`
- Dark background: `oklch(0.155 0 0)`
- Dark surface: `oklch(0.205 0 0)`
- Dark ink: `oklch(0.955 0 0)`
- Muted text: system secondary label color
- Success, warning, and error: semantic system colors with symbol and text labels, never color alone

## Typography

Use SF Pro through SwiftUI semantic text styles. Headline and metric values use semibold weight. Secondary labels use caption styles. Numeric values use monospaced digits without switching the whole interface to a monospaced face.

## Layout

- Panel width: 420 points; content maximum height: 620 points
- Four-point spacing scale: 4, 8, 12, 16, 24
- Fixed header and profile tabs; vertically scrolling statistics content
- Tabs scroll horizontally when profiles exceed the available width
- Related values share rows and sections separated by native dividers, not nested cards

## Components

- Menu-bar item: monochrome `cpu` SF Symbol with the accessible name “Agent Tray”
- Profile tab: provider symbol, compact name, selected tint, keyboard focus, and selected accessibility trait
- Usage row: label, percentage, reset text, and native linear progress indicator
- Metric row: leading label and trailing monospaced value
- State notice: semantic symbol, title, recovery detail, and optional retry action
- Toolbar buttons: Refresh and Settings, each with tooltip and accessibility label

## Motion

Use 150–200 ms opacity transitions for profile changes and refreshed values. Disable nonessential transitions when Reduce Motion is enabled. Never animate layout or progress from a fabricated zero state.
