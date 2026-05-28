# ChromaForge CLI

`chromaforge-cli.swift` is a lightweight command-line companion for ChromaForge. It extracts colors from CSS, JSON, token files, or plain text, then audits every ordered foreground/background pair against WCAG contrast gates.

Use it when you want a repeatable color check in a design-system repo, app repo, website repo, or CI workflow.

## Requirements

- macOS with Swift installed.
- A text-based file that contains color values.

The script can be run directly with Swift from the ChromaForge project root:

```sh
swift Tools/chromaforge-cli.swift help
```

## Commands

Extract unique colors:

```sh
swift Tools/chromaforge-cli.swift extract path/to/tokens-or-css-file.css
```

Audit all ordered foreground/background color pairs against WCAG AA normal-text contrast:

```sh
swift Tools/chromaforge-cli.swift audit path/to/tokens-or-css-file.css
```

Choose a different contrast gate:

```sh
swift Tools/chromaforge-cli.swift audit path/to/tokens-or-css-file.css --gate large
swift Tools/chromaforge-cli.swift audit path/to/tokens-or-css-file.css --gate aaa
```

Emit JSON for automation:

```sh
swift Tools/chromaforge-cli.swift extract path/to/tokens-or-css-file.css --json
swift Tools/chromaforge-cli.swift audit path/to/tokens-or-css-file.css --json
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
ChromaForge audit: app-theme.css
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
swift Tools/chromaforge-cli.swift audit DesignTokens/colors.css --gate aa
```

For GitHub Actions, place the script in your repository and add a step like:

```yaml
- name: Audit color contrast
  run: swift Tools/chromaforge-cli.swift audit DesignTokens/colors.css --gate aa
```

Use `--json` if you want to capture results and render them in a custom report.

## Current Scope

The CLI is intentionally narrower than the ChromaForge app. It is best for automated contrast checks on text-based files. The app remains the richer authoring tool for importing palettes, generating perceptual ramps, repairing semantic contrast, creating Figma handoff, and exporting framework-specific formats.

The CLI currently extracts hex, RGB, and HSL-style colors. It does not yet parse OKLCH, Lab/LCH, Display-P3, CSS custom property references, computed CSS values, images, or live websites.

## Recommended User Distribution

For early release, the best user-facing path is:

1. Include this README in the project and link to it from the in-app User Guide and support website.
2. Offer the script as an optional developer download from the ChromaForge support site or a public GitHub release.
3. For non-technical users, keep CLI guidance framed as an optional CI/developer tool, not as part of the core app workflow.
4. For a polished public release, ship a notarized universal macOS binary named `chromaforge` in a `.zip`, alongside this source script, checksum, and example files.

Avoid trying to install the CLI from the App Store app itself. App Store apps should not place command-line tools into locations such as `/usr/local/bin`; an external download or repository release is cleaner and easier for users to update.
