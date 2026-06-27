# PaletteWright CLI

`palettewright-cli.swift` is a lightweight command-line companion for PaletteWright. It extracts colors from CSS, JSON, token files, or plain text, then audits every ordered foreground/background pair against WCAG contrast gates.

Use it when you want a repeatable color check in a design-system repo, app repo, website repo, or CI workflow.

In the PaletteWright Mac app, choose Tools > CLI Utility to see common command examples, or Tools > Copy CLI Audit Command to copy a starter audit command to the pasteboard.

## Requirements

- macOS with Swift installed.
- A text-based file that contains color values.

The script can be run directly with Swift from the PaletteWright project root:

```sh
swift Tools/palettewright-cli.swift help
swift Tools/palettewright-cli.swift version
```

## Commands

Print the CLI version:

```sh
swift Tools/palettewright-cli.swift version
```

Extract unique colors:

```sh
swift Tools/palettewright-cli.swift extract path/to/tokens-or-css-file.css
```

Audit all ordered foreground/background color pairs against WCAG AA normal-text contrast:

```sh
swift Tools/palettewright-cli.swift audit path/to/tokens-or-css-file.css
```

Choose a different contrast gate:

```sh
swift Tools/palettewright-cli.swift audit path/to/tokens-or-css-file.css --gate large
swift Tools/palettewright-cli.swift audit path/to/tokens-or-css-file.css --gate aaa
```

Emit JSON for automation:

```sh
swift Tools/palettewright-cli.swift extract path/to/tokens-or-css-file.css --json
swift Tools/palettewright-cli.swift audit path/to/tokens-or-css-file.css --json
```

## Supported Color Syntax

- `#RGB`
- `#RGBA`
- `#RRGGBB`
- `#RRGGBBAA`
- `rgb()`
- `rgba()`
- Modern space-separated RGB syntax
- `hsl()`
- `hsla()`
- `hwb()`
- `lab()`
- `lch()`
- `oklab()`
- `oklch()`
- `color(display-p3 ...)`
- Structured JSON color objects using `hex`, `red` / `green` / `blue`, or `components` with `colorSpace`, `space`, or `model`

Alpha channels are accepted during extraction but ignored for contrast calculations. The CLI audits the rendered RGB color values.

## Audit Gates

| Gate | Ratio | Use |
| --- | ---: | --- |
| `large` | 3.0:1 | Large text and meaningful non-text UI boundaries |
| `aa` | 4.5:1 | WCAG AA normal text |
| `aaa` | 7.0:1 | WCAG AAA normal text |

`aa` is the default gate.

## Exit Codes

| Code | Meaning |
| ---: | --- |
| `0` | Command succeeded. For `audit`, every color pair met the selected gate. |
| `1` | Runtime failure, insufficient colors for audit, no extractable colors, or audit gate failure. |
| `2` | Invalid arguments. |

These exit codes are intended for CI. A failing audit exits with `1`, so a build step can stop when a palette or token file does not meet the selected gate.

## Example Output

```text
PaletteWright audit: app-theme.css
Gate: AA normal 4.5:1
Colors: 4
Pairs: 12
Passing gate: 8/12
AA normal: 8/12
AA large / non-text: 10/12
AAA: 4/12
Weakest: #777777 on #888888 1.26:1
Strongest: #000000 on #FFFFFF 21.00:1
```

## CI Example

```sh
swift Tools/palettewright-cli.swift audit DesignTokens/colors.css --gate aa
```

For GitHub Actions, place the script in your repository and add a step like:

```yaml
- name: Audit color contrast
  run: swift Tools/palettewright-cli.swift audit DesignTokens/colors.css --gate aa
```

Use `--json` if you want to capture results and render them in a custom report.

## Current Scope

The CLI is intentionally narrower than the PaletteWright app. It is best for automated contrast checks on text-based files. The app remains the richer authoring tool for importing palettes, generating perceptual ramps, repairing semantic contrast, creating Figma handoff, and exporting framework-specific formats.

The CLI currently extracts the same text color syntaxes used by PaletteWright's paste, file, and website import paths: hex, RGB, HSL, HWB, Lab/LCH, OKLab/OKLCH, Display-P3, and common structured JSON color objects. It does not parse CSS custom property references, computed CSS values, images, or live websites.
