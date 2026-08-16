# PaletteWright CLI

`palettewright-cli.swift` is PaletteWright's deterministic command-line compiler and CI companion. It scans, compiles, checks, diffs, repairs, and watches text-based color sources.

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

The 2.2 workflow commands are:

```sh
swift Tools/palettewright-cli.swift scan Sources --json
swift Tools/palettewright-cli.swift compile tokens.json --format css --output Generated/colors.css
swift Tools/palettewright-cli.swift check tokens.css --manifest palettewright-pairs.json --level aa --sarif > palettewright.sarif
swift Tools/palettewright-cli.swift diff before.css after.css --json
swift Tools/palettewright-cli.swift fix tokens.css --manifest palettewright-pairs.json --output Generated/tokens-fixed.css
swift Tools/palettewright-cli.swift watch Sources --format json --output Generated/colors.json
```

`compile` sorts normalized colors before naming them, so unchanged input always produces byte-for-byte stable output. `fix` never overwrites its source; pass `--output` to write a reviewed repair candidate.

Print the CLI version:

```sh
swift Tools/palettewright-cli.swift version
```

The regression inputs used by the examples and release checks live in `Tools/Fixtures`. Keep that directory with the public CLI repository so users and CI maintainers can reproduce declared-pair, duplicate-literal, low-contrast, Display-P3, and alpha-context behavior.

Extract unique colors:

```sh
swift Tools/palettewright-cli.swift extract path/to/tokens-or-css-file.css
```

Explore all ordered foreground/background color pairs:

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

Alpha channels are retained and composited when every solid layer is known. Unknown underlayers and unsupported rendered context return `needsReview`.

## Semantic Conformance Gate

Use a semantic pair manifest for CI:

```json
{
  "pairs": [
    {
      "foreground": "button.primary.label",
      "background": "button.primary.background",
      "usage": "normalText",
      "modes": ["light", "dark", "increasedContrast"],
      "states": ["default", "hover", "pressed", "focus"]
    }
  ]
}
```

```sh
swift Tools/palettewright-cli.swift check tokens.css --manifest palettewright-pairs.json --method both
swift Tools/palettewright-cli.swift check tokens.css --manifest palettewright-pairs.json --sarif
swift Tools/palettewright-cli.swift fix tokens.css --manifest palettewright-pairs.json --output tokens.repaired.css
```

Usage values are `normalText`, `largeText`, `nonTextUI`, `graphic`, and `decorative`. AA/AAA thresholds are derived from usage. WCAG 2.2 remains normative; [APCA-W3 0.1.9 / 0.0.98G-4g](https://github.com/Myndex/apca-w3) is signed, polarity-aware, supplemental, and experimental. It does not claim conformance with the [work-in-progress WCAG 3 standard](https://www.w3.org/WAI/standards-guidelines/wcag/wcag3-intro/).

Every calculated relationship retains both the unrounded WCAG result and signed APCA Lc so disagreements stay visible. `--method apca` selects APCA as the primary report view but does not invent an APCA conformance threshold; `decisionBasis` identifies WCAG 2.2 wherever pass/fail is present.

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
| `0` | Command succeeded. For `check`, every calculated normative relationship passed and none needed review. |
| `1` | Runtime failure, insufficient context, no extractable colors, a failed relationship, or a needs-review result. |
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

The CLI is the deterministic repository and CI companion to PaletteWright 2.2. It scans supported source trees, compiles normalized color output, checks declared semantic relationships with text, JSON, or SARIF reporting, diffs color sets, writes non-destructive repair candidates, and watches folders for changes. The app remains the visual authoring surface for capture, perceptual palette construction, semantic role editing, live component previews, and Figma handoff.

The CLI extracts the same text color syntaxes used by PaletteWright's paste, file, and website import paths: hex, RGB, HSL, HWB, Lab/LCH, OKLab/OKLCH, Display-P3, and common structured JSON color objects. It does not evaluate runtime CSS custom-property references, computed browser styles, images, or live websites.
