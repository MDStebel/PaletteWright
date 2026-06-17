#!/usr/bin/env swift
//
//  palettewright-cli.swift
//  PaletteWright
//
//  Created by Michael Stebel on 5/19/26.
//  Updated by Michael on 5/29/26.
//

import Foundation

/// Represents a parsed OKLab color.
struct OKLab {
    var lightness: Double
    var a: Double
    var b: Double
}

/// Represents a parsed OKLCH color.
struct OKLCH {
    var lightness: Double
    var chroma: Double
    var hueDegrees: Double
}

/// Represents a parsed CIE Lab color.
struct CIELab {
    var lightness: Double
    var a: Double
    var b: Double
}

/// Represents a parsed CIE LCH color.
struct CIELCH {
    var lightness: Double
    var chroma: Double
    var hueDegrees: Double
}

/// Represents a parsed RGB color in normalized channel space.
struct RGB: Hashable {
    var red: Double
    var green: Double
    var blue: Double

    /// Creates a color by clamping normalized RGB channels into displayable bounds.
    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Creates a color from shorthand, RGB, or RGBA hexadecimal text.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let normalized: String
        switch cleaned.count {
        case 3, 4:
            normalized = String(cleaned.prefix(3).flatMap { [$0, $0] })
        case 6:
            normalized = cleaned
        case 8:
            normalized = String(cleaned.prefix(6))
        default:
            normalized = cleaned
        }

        let value = Int(normalized, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// Returns the color as a six-digit hexadecimal string.
    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }

    /// Calculates relative luminance for contrast checks.
    var luminance: Double {
        /// Converts an encoded RGB channel into linear light.
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Calculates the WCAG contrast ratio against another RGB color.
    func contrast(with other: RGB) -> Double {
        let first = luminance
        let second = other.luminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Converts the color into OKLab space.
    var okLab: OKLab {
        let r = Self.linearized(red)
        let g = Self.linearized(green)
        let b = Self.linearized(blue)

        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let lPrime = cbrt(l)
        let mPrime = cbrt(m)
        let sPrime = cbrt(s)

        return OKLab(
            lightness: 0.2104542553 * lPrime + 0.7936177850 * mPrime - 0.0040720468 * sPrime,
            a: 1.9779984951 * lPrime - 2.4285922050 * mPrime + 0.4505937099 * sPrime,
            b: 0.0259040371 * lPrime + 0.7827717662 * mPrime - 0.8086757660 * sPrime
        )
    }

    /// Converts the color into OKLCH space.
    var okLCH: OKLCH {
        let lab = okLab
        let chroma = sqrt(lab.a * lab.a + lab.b * lab.b)
        let hue = Self.normalizedHue(atan2(lab.b, lab.a) * 180.0 / .pi)
        return OKLCH(lightness: lab.lightness, chroma: chroma, hueDegrees: hue)
    }

    /// Converts an OKLab color into RGB.
    static func fromOKLab(_ lab: OKLab) -> RGB {
        let lPrime = lab.lightness + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let mPrime = lab.lightness - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let sPrime = lab.lightness - 0.0894841775 * lab.a - 1.2914855480 * lab.b

        let l = lPrime * lPrime * lPrime
        let m = mPrime * mPrime * mPrime
        let s = sPrime * sPrime * sPrime

        return RGB(
            red: Self.encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: Self.encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: Self.encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    /// Converts an OKLCH color into RGB.
    static func fromOKLCH(_ lch: OKLCH) -> RGB {
        let radians = normalizedHue(lch.hueDegrees) * .pi / 180.0
        return fromOKLab(
            OKLab(
                lightness: min(max(lch.lightness, 0), 1),
                a: cos(radians) * max(lch.chroma, 0),
                b: sin(radians) * max(lch.chroma, 0)
            )
        )
    }

    /// Converts a CIE Lab color into RGB using the CSS D50 white point.
    static func fromCIELab(_ lab: CIELab) -> RGB {
        let lightness = min(max(lab.lightness, 0), 100)
        let y = (lightness + 16) / 116
        let x = lab.a / 500 + y
        let z = y - lab.b / 200

        let xyzD50 = (
            x: d50White.x * labInverse(x),
            y: d50White.y * labInverse(y),
            z: d50White.z * labInverse(z)
        )
        let xyzD65 = adaptD50ToD65(xyzD50)
        let linearRGB = xyzD65ToLinearSRGB(xyzD65)

        return RGB(
            red: encoded(linearRGB.red),
            green: encoded(linearRGB.green),
            blue: encoded(linearRGB.blue)
        )
    }

    /// Converts a CIE LCH color into RGB using the CSS D50 white point.
    static func fromCIELCH(_ lch: CIELCH) -> RGB {
        let radians = normalizedHue(lch.hueDegrees) * .pi / 180.0
        return fromCIELab(
            CIELab(
                lightness: lch.lightness,
                a: cos(radians) * max(lch.chroma, 0),
                b: sin(radians) * max(lch.chroma, 0)
            )
        )
    }

    /// Converts CIE XYZ with a D65 white point into linear-light sRGB.
    private static func xyzD65ToLinearSRGB(_ xyz: (x: Double, y: Double, z: Double)) -> (red: Double, green: Double, blue: Double) {
        (
            red: 3.2409699419 * xyz.x - 1.5373831776 * xyz.y - 0.4986107603 * xyz.z,
            green: -0.9692436363 * xyz.x + 1.8759675015 * xyz.y + 0.0415550574 * xyz.z,
            blue: 0.0556300797 * xyz.x - 0.2039769589 * xyz.y + 1.0569715142 * xyz.z
        )
    }

    /// Adapts CIE XYZ values from D50 to D65 using the Bradford transform.
    private static func adaptD50ToD65(_ xyz: (x: Double, y: Double, z: Double)) -> (x: Double, y: Double, z: Double) {
        (
            x: 0.9554734215 * xyz.x + 0.0230984549 * xyz.y + 0.0632592432 * xyz.z,
            y: -0.0283697093 * xyz.x + 1.0099954580 * xyz.y + 0.0210413990 * xyz.z,
            z: 0.0123140149 * xyz.x - 0.0205076493 * xyz.y + 1.3303659262 * xyz.z
        )
    }

    /// Applies the CIE Lab inverse transfer function.
    private static func labInverse(_ value: Double) -> Double {
        let cubed = value * value * value
        return cubed > labEpsilon ? cubed : (116 * value - 16) / labKappa
    }

    /// Converts an encoded RGB channel to linear light.
    private static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Converts a linear-light RGB channel to encoded sRGB.
    private static func encoded(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    /// Normalizes a hue angle into the 0-360 range.
    private static func normalizedHue(_ value: Double) -> Double {
        var hue = value.truncatingRemainder(dividingBy: 360)
        if hue < 0 {
            hue += 360
        }
        return hue
    }

    private static let d50White = (x: 0.9642956764, y: 1.0, z: 0.8251046025)
    private static let labEpsilon = 216.0 / 15_625.0
    private static let labKappa = 24_389.0 / 27.0
}

/// Stores one discovered color and where it came from.
struct ColorMatch: Hashable {
    var color: RGB
    var source: String
    var line: Int
    var column: Int

    /// Provides a stable key for deduplicating colors by rendered value.
    var key: String { color.hex }

    /// Provides a stable location key that keeps structured JSON colors after text matches.
    var sortLocation: (line: Int, column: Int) {
        (line == 0 ? Int.max : line, column == 0 ? Int.max : column)
    }

    /// Returns a user-facing location label.
    var locationDescription: String {
        line > 0 ? "line \(line), column \(column)" : "structured JSON"
    }

    /// Returns a JSON-compatible location value.
    var locationDictionary: [String: Any] {
        [
            "line": line > 0 ? line : NSNull(),
            "column": column > 0 ? column : NSNull()
        ]
    }
}

/// Names the supported contrast gates for audit mode.
enum ContrastGate: String {
    case large
    case aa
    case aaa

    /// Returns the minimum contrast ratio required by this gate.
    var threshold: Double {
        switch self {
        case .large:
            return 3
        case .aa:
            return 4.5
        case .aaa:
            return 7
        }
    }

    /// Returns a compact label for command output.
    var label: String {
        switch self {
        case .large:
            return "AA large / non-text"
        case .aa:
            return "AA normal"
        case .aaa:
            return "AAA"
        }
    }
}

/// Names the available top-level CLI commands.
enum Command {
    case audit(filePath: String, gate: ContrastGate, json: Bool)
    case extract(filePath: String, json: Bool)
    case help
}

/// Describes an argument parsing or runtime failure.
enum CLIError: LocalizedError {
    case unknownCommand(String)
    case missingFile(String)
    case unreadableFile(String)
    case unknownOption(String)
    case missingOptionValue(String)
    case invalidGate(String)

    /// Returns the user-facing error message.
    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .missingFile(let command):
            return "Missing file path for \(command)."
        case .unreadableFile(let path):
            return "Could not read \(path)."
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        case .missingOptionValue(let option):
            return "Missing value for \(option)."
        case .invalidGate(let value):
            return "Invalid gate '\(value)'. Use large, aa, or aaa."
        }
    }
}

/// Prints command usage to standard output or standard error.
func printUsage(to stream: UnsafeMutablePointer<FILE> = stdout) {
    fputs(
        """
        PaletteWright CLI

        Usage:
          swift Tools/palettewright-cli.swift audit <file> [--gate aa|aaa|large] [--json]
          swift Tools/palettewright-cli.swift extract <file> [--json]
          swift Tools/palettewright-cli.swift help

        Commands:
          audit    Extract colors and report WCAG contrast coverage.
          extract  List unique colors discovered in a CSS/JSON/text file.

        Supported color syntax:
          #RGB, #RGBA, #RRGGBB, #RRGGBBAA
          rgb(), rgba(), hsl(), hsla(), hwb()
          lab(), lch(), oklab(), oklch(), color(display-p3 ...)
          JSON hex/RGB/component color objects

        Exit codes:
          0  Command succeeded. For audit, every pair met the selected gate.
          1  Runtime failure or audit gate failure.
          2  Invalid arguments.

        """,
        stream
    )
}

/// Parses raw command-line arguments into a command value.
func parseCommand(_ arguments: [String]) throws -> Command {
    guard let command = arguments.first else {
        return .help
    }

    switch command {
    case "help", "--help", "-h":
        return .help
    case "audit":
        return try parseAuditCommand(Array(arguments.dropFirst()))
    case "extract":
        return try parseExtractCommand(Array(arguments.dropFirst()))
    default:
        throw CLIError.unknownCommand(command)
    }
}

/// Parses options for the audit command.
func parseAuditCommand(_ arguments: [String]) throws -> Command {
    var filePath: String?
    var gate = ContrastGate.aa
    var json = false
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--json":
            json = true
        case "--gate":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw CLIError.missingOptionValue(argument)
            }
            guard let parsedGate = ContrastGate(rawValue: arguments[nextIndex].lowercased()) else {
                throw CLIError.invalidGate(arguments[nextIndex])
            }
            gate = parsedGate
            index = nextIndex
        default:
            if argument.hasPrefix("-") {
                throw CLIError.unknownOption(argument)
            }
            filePath = argument
        }

        index += 1
    }

    guard let filePath else {
        throw CLIError.missingFile("audit")
    }

    return .audit(filePath: filePath, gate: gate, json: json)
}

/// Parses options for the extract command.
func parseExtractCommand(_ arguments: [String]) throws -> Command {
    var filePath: String?
    var json = false

    for argument in arguments {
        switch argument {
        case "--json":
            json = true
        default:
            if argument.hasPrefix("-") {
                throw CLIError.unknownOption(argument)
            }
            filePath = argument
        }
    }

    guard let filePath else {
        throw CLIError.missingFile("extract")
    }

    return .extract(filePath: filePath, json: json)
}

/// Reads a UTF-8 text file for color extraction.
func readTextFile(at path: String) throws -> (URL, String) {
    let fileURL = URL(fileURLWithPath: path)
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
        throw CLIError.unreadableFile(fileURL.path)
    }
    return (fileURL, text)
}

/// Extracts supported CSS-style colors from arbitrary text.
func extractColorMatches(from text: String) -> [ColorMatch] {
    var matches: [ColorMatch] = []
    matches += hexColorMatches(in: text)
    matches += rgbColorMatches(in: text)
    matches += hslColorMatches(in: text)
    matches += hwbColorMatches(in: text)
    matches += cieLabColorMatches(in: text)
    matches += cieLCHColorMatches(in: text)
    matches += okLabColorMatches(in: text)
    matches += okLCHColorMatches(in: text)
    matches += displayP3ColorMatches(in: text)
    matches += structuredJSONColorMatches(in: text)

    var seen: Set<String> = []
    return matches
        .sorted {
            let firstLocation = $0.sortLocation
            let secondLocation = $1.sortLocation
            if firstLocation.line != secondLocation.line {
                return firstLocation.line < secondLocation.line
            }
            if firstLocation.column != secondLocation.column {
                return firstLocation.column < secondLocation.column
            }
            if $0.source != $1.source {
                return $0.source < $1.source
            }
            return $0.color.hex < $1.color.hex
        }
        .filter { match in
            seen.insert(match.key).inserted
        }
}

/// Extracts hexadecimal color literals.
func hexColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\\b",
        in: text
    ).compactMap { raw, range in
        let hex = normalizeHex(raw)
        guard hex.count == 7 else {
            return nil
        }
        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(color: RGB(hex: hex), source: raw, line: location.line, column: location.column)
    }
}

/// Extracts rgb() and rgba() color functions.
func rgbColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "rgba?\\s*\\(([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "rgba?\\s*\\(([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let red = channelValue(from: components[0]),
              let green = channelValue(from: components[1]),
              let blue = channelValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: RGB(red: red, green: green, blue: blue),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts hsl() and hsla() color functions.
func hslColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "hsla?\\s*\\(([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "hsla?\\s*\\(([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let hue = hueValue(from: components[0]),
              let saturation = percentValue(from: components[1]),
              let lightness = percentValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: rgbFromHSL(hue: hue, saturation: saturation, lightness: lightness),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts hwb() color functions.
func hwbColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "hwb\\s*\\(([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "hwb\\s*\\(([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let hue = hueValue(from: components[0]),
              let whiteness = percentValue(from: components[1]),
              let blackness = percentValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: rgbFromHWB(hue: hue, whiteness: whiteness, blackness: blackness),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts CIE lab() color functions.
func cieLabColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "\\blab\\s*\\(([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "\\blab\\s*\\(([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let lightness = cieLightnessValue(from: components[0]),
              let a = cieLabAxisValue(from: components[1]),
              let b = cieLabAxisValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: RGB.fromCIELab(CIELab(lightness: lightness, a: a, b: b)),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts CIE lch() color functions.
func cieLCHColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "\\blch\\s*\\(([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "\\blch\\s*\\(([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let lightness = cieLightnessValue(from: components[0]),
              let chroma = cieChromaValue(from: components[1]),
              let hue = hueValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: RGB.fromCIELCH(CIELCH(lightness: lightness, chroma: chroma, hueDegrees: hue)),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts oklab() color functions.
func okLabColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "oklab\\s*\\(([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "oklab\\s*\\(([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let lightness = lightnessValue(from: components[0]),
              let a = chromaAxisValue(from: components[1]),
              let b = chromaAxisValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: RGB.fromOKLab(OKLab(lightness: lightness, a: a, b: b)),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts oklch() color functions.
func okLCHColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "oklch\\s*\\(([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "oklch\\s*\\(([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let lightness = lightnessValue(from: components[0]),
              let chroma = chromaValue(from: components[1]),
              let hue = hueValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: RGB.fromOKLCH(OKLCH(lightness: lightness, chroma: chroma, hueDegrees: hue)),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts color(display-p3 ...) color functions.
func displayP3ColorMatches(in text: String) -> [ColorMatch] {
    regexMatches(
        pattern: "color\\s*\\(\\s*display-p3\\s+([^\\)]*)\\)",
        in: text,
        options: [.caseInsensitive]
    ).compactMap { raw, range in
        guard let components = firstCapture(
            pattern: "color\\s*\\(\\s*display-p3\\s+([^\\)]*)\\)",
            in: raw,
            options: [.caseInsensitive]
        ).map(componentTokens),
              components.count >= 3,
              let red = unitIntervalValue(from: components[0]),
              let green = unitIntervalValue(from: components[1]),
              let blue = unitIntervalValue(from: components[2]) else {
            return nil
        }

        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: RGB(red: red, green: green, blue: blue),
            source: raw,
            line: location.line,
            column: location.column
        )
    }
}

/// Extracts recognized structured JSON color objects.
func structuredJSONColorMatches(in text: String) -> [ColorMatch] {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        return []
    }

    return jsonColors(in: object).map {
        ColorMatch(color: $0.color, source: $0.source, line: 0, column: 0)
    }
}

/// Normalizes shorthand and alpha hex values to #RRGGBB.
func normalizeHex(_ value: String) -> String {
    let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    switch hex.count {
    case 3, 4:
        let expanded = hex.prefix(3).flatMap { [$0, $0] }
        return "#\(String(expanded).uppercased())"
    case 6:
        return "#\(hex.uppercased())"
    case 8:
        return "#\(hex.prefix(6).uppercased())"
    default:
        return value.uppercased()
    }
}

/// Stores one color found in structured JSON.
struct JSONColorHit {
    var color: RGB
    var source: String
}

/// Recursively extracts structured JSON color component objects.
func jsonColors(in object: Any) -> [JSONColorHit] {
    if let dictionary = object as? [String: Any] {
        var colors: [JSONColorHit] = []
        if let color = jsonColor(from: dictionary) {
            colors.append(color)
        }

        for value in dictionary.values {
            colors += jsonColors(in: value)
        }
        return colors
    }

    if let array = object as? [Any] {
        return array.flatMap(jsonColors(in:))
    }

    return []
}

/// Extracts a single JSON color object when its shape is recognized.
func jsonColor(from dictionary: [String: Any]) -> JSONColorHit? {
    if let hex = stringValue(dictionary["hex"] ?? dictionary["$value"] ?? dictionary["value"] ?? dictionary["color"]),
       hex.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
        return JSONColorHit(color: RGB(hex: hex), source: "JSON hex")
    }

    if let red = numericValue(dictionary["r"] ?? dictionary["red"]),
       let green = numericValue(dictionary["g"] ?? dictionary["green"]),
       let blue = numericValue(dictionary["b"] ?? dictionary["blue"]) {
        return JSONColorHit(color: rgbColor(from: [red, green, blue]), source: "JSON RGB components")
    }

    guard let components = dictionary["components"] as? [Any] else {
        return nil
    }

    let numbers = components.compactMap(numericValue)
    guard numbers.count >= 3 else {
        return nil
    }

    let space = stringValue(dictionary["colorSpace"] ?? dictionary["space"] ?? dictionary["model"])?
        .lowercased()
        .replacingOccurrences(of: "_", with: "-") ?? "srgb"

    if space.contains("oklch") {
        return JSONColorHit(
            color: RGB.fromOKLCH(OKLCH(lightness: numbers[0], chroma: numbers[1], hueDegrees: numbers[2])),
            source: "JSON OKLCH components"
        )
    }

    if space.contains("oklab") {
        return JSONColorHit(
            color: RGB.fromOKLab(OKLab(lightness: numbers[0], a: numbers[1], b: numbers[2])),
            source: "JSON OKLab components"
        )
    }

    if space.contains("lch") {
        return JSONColorHit(
            color: RGB.fromCIELCH(
                CIELCH(
                    lightness: numbers[0] <= 1 ? numbers[0] * 100 : numbers[0],
                    chroma: numbers[1],
                    hueDegrees: numbers[2]
                )
            ),
            source: "JSON LCH components"
        )
    }

    if space.contains("lab") {
        return JSONColorHit(
            color: RGB.fromCIELab(
                CIELab(
                    lightness: numbers[0] <= 1 ? numbers[0] * 100 : numbers[0],
                    a: numbers[1],
                    b: numbers[2]
                )
            ),
            source: "JSON Lab components"
        )
    }

    return JSONColorHit(color: rgbColor(from: Array(numbers.prefix(3))), source: "JSON RGB components")
}

/// Converts RGB-like components into a color.
func rgbColor(from components: [Double]) -> RGB {
    let values = components.map { abs($0) > 1 ? $0 / 255 : $0 }
    return RGB(red: values[0], green: values[1], blue: values[2])
}

/// Reads a JSON string-like value.
func stringValue(_ value: Any?) -> String? {
    if let string = value as? String {
        return string
    }

    return nil
}

/// Reads a JSON numeric value.
func numericValue(_ value: Any?) -> Double? {
    if value is Bool {
        return nil
    }

    if let number = value as? NSNumber {
        return number.doubleValue
    }

    if let string = value as? String {
        return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return nil
}

/// Splits color function arguments while ignoring alpha separators.
func componentTokens(from value: String) -> [String] {
    value
        .replacingOccurrences(of: ",", with: " ")
        .replacingOccurrences(of: "/", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
}

/// Parses an RGB channel from an integer or percentage token.
func channelValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasSuffix("%") {
        guard let percent = Double(cleaned.dropLast()) else {
            return nil
        }
        return min(max(percent / 100, 0), 1)
    }

    guard let number = Double(cleaned) else {
        return nil
    }

    return min(max(number / 255, 0), 1)
}

/// Parses a percentage token into a normalized unit value.
func percentValue(from value: String) -> Double? {
    let cleaned = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "%"))

    guard let number = Double(cleaned) else {
        return nil
    }

    return min(max(number / 100, 0), 1)
}

/// Parses a component constrained to the zero-to-one range.
func unitIntervalValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasSuffix("%") {
        guard let number = Double(cleaned.dropLast()) else {
            return nil
        }

        return min(max(number / 100, 0), 1)
    }

    guard let number = Double(cleaned) else {
        return nil
    }

    return min(max(number, 0), 1)
}

/// Parses an OKLab or OKLCH lightness component.
func lightnessValue(from value: String) -> Double? {
    unitIntervalValue(from: value)
}

/// Parses a CIE Lab or LCH lightness component.
func cieLightnessValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasSuffix("%") {
        guard let number = Double(cleaned.dropLast()) else {
            return nil
        }

        return min(max(number, 0), 100)
    }

    guard let number = Double(cleaned) else {
        return nil
    }

    return min(max(number, 0), 100)
}

/// Parses a CIE Lab a or b axis component.
func cieLabAxisValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasSuffix("%") {
        guard let number = Double(cleaned.dropLast()) else {
            return nil
        }

        return number * 1.25
    }

    return Double(cleaned)
}

/// Parses a CIE LCH chroma component.
func cieChromaValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasSuffix("%") {
        guard let number = Double(cleaned.dropLast()) else {
            return nil
        }

        return max(number * 1.5, 0)
    }

    guard let number = Double(cleaned) else {
        return nil
    }

    return max(number, 0)
}

/// Parses an OKLCH chroma component.
func chromaValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasSuffix("%") {
        guard let number = Double(cleaned.dropLast()) else {
            return nil
        }

        return max(number / 250, 0)
    }

    guard let number = Double(cleaned) else {
        return nil
    }

    return max(number, 0)
}

/// Parses an OKLab chroma axis component.
func chromaAxisValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasSuffix("%") {
        guard let number = Double(cleaned.dropLast()) else {
            return nil
        }

        return number / 100
    }

    return Double(cleaned)
}

/// Parses hue values expressed as turns, radians, degrees, or numbers.
func hueValue(from value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if cleaned.hasSuffix("turn"), let number = Double(cleaned.dropLast(4)) {
        return number * 360
    }

    if cleaned.hasSuffix("rad"), let number = Double(cleaned.dropLast(3)) {
        return number * 180 / .pi
    }

    if cleaned.hasSuffix("deg"), let number = Double(cleaned.dropLast(3)) {
        return number
    }

    return Double(cleaned)
}

/// Converts HSL components into an RGB color.
func rgbFromHSL(hue: Double, saturation: Double, lightness: Double) -> RGB {
    let chroma = (1 - abs(2 * lightness - 1)) * saturation
    let huePrime = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
    let match = lightness - chroma / 2

    let components: (Double, Double, Double)
    switch huePrime {
    case 0..<1:
        components = (chroma, x, 0)
    case 1..<2:
        components = (x, chroma, 0)
    case 2..<3:
        components = (0, chroma, x)
    case 3..<4:
        components = (0, x, chroma)
    case 4..<5:
        components = (x, 0, chroma)
    default:
        components = (chroma, 0, x)
    }

    return RGB(red: components.0 + match, green: components.1 + match, blue: components.2 + match)
}

/// Converts HWB components into an RGB color.
func rgbFromHWB(hue: Double, whiteness: Double, blackness: Double) -> RGB {
    if whiteness + blackness >= 1 {
        let gray = whiteness / (whiteness + blackness)
        return RGB(red: gray, green: gray, blue: gray)
    }

    let base = rgbFromHSL(hue: hue, saturation: 1, lightness: 0.5)
    let factor = 1 - whiteness - blackness
    return RGB(
        red: base.red * factor + whiteness,
        green: base.green * factor + whiteness,
        blue: base.blue * factor + whiteness
    )
}

/// Returns the one-based line and column for a UTF-16 text offset.
func lineColumn(for location: Int, in text: String) -> (line: Int, column: Int) {
    var line = 1
    var column = 1
    var offset = 0

    for scalar in text.unicodeScalars {
        guard offset < location else {
            break
        }

        if scalar == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        offset += String(scalar).utf16.count
    }

    return (line, column)
}

/// Returns the first capture group for a regular expression match.
func firstCapture(
    pattern: String,
    in text: String,
    options: NSRegularExpression.Options = []
) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return nil
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: text) else {
        return nil
    }

    return String(text[captureRange])
}

/// Returns all regex matches with their source ranges.
func regexMatches(
    pattern: String,
    in text: String,
    options: NSRegularExpression.Options = []
) -> [(String, NSRange)] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return []
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        guard let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return (String(text[matchRange]), match.range)
    }
}

/// Builds all ordered foreground/background contrast pairs.
func contrastPairs(for colors: [RGB]) -> [(foreground: RGB, background: RGB, ratio: Double)] {
    colors.flatMap { foreground in
        colors.filter { $0.hex != foreground.hex }.map { background in
            (foreground, background, foreground.contrast(with: background))
        }
    }
}

/// Runs the extract command and returns the process exit code.
func runExtract(filePath: String, json: Bool) throws -> Int32 {
    let (fileURL, text) = try readTextFile(at: filePath)
    let matches = extractColorMatches(from: text)

    if json {
        printJSON([
            "file": fileURL.path,
            "colors": matches.map {
                var color: [String: Any] = [
                    "hex": $0.color.hex,
                    "source": $0.source
                ]
                color.merge($0.locationDictionary) { current, _ in current }
                return color
            }
        ])
    } else {
        print("PaletteWright extract: \(fileURL.lastPathComponent)")
        print("Colors: \(matches.count)")
        for match in matches {
            print("\(match.color.hex)  \(match.source)  \(match.locationDescription)")
        }
    }

    return matches.isEmpty ? 1 : 0
}

/// Runs the audit command and returns the process exit code.
func runAudit(filePath: String, gate: ContrastGate, json: Bool) throws -> Int32 {
    let (fileURL, text) = try readTextFile(at: filePath)
    let matches = extractColorMatches(from: text)
    let colors = matches.map(\.color)

    guard colors.count >= 2 else {
        if json {
            printJSON([
                "file": fileURL.path,
                "colors": colors.count,
                "error": "Need at least 2 colors to audit contrast."
            ])
        } else {
            print("Found \(colors.count) color. Need at least 2 colors to audit contrast.")
        }
        return 1
    }

    let pairs = contrastPairs(for: colors)
    let passing = pairs.filter { $0.ratio >= gate.threshold }
    let aa = pairs.filter { $0.ratio >= ContrastGate.aa.threshold }.count
    let large = pairs.filter { $0.ratio >= ContrastGate.large.threshold }.count
    let aaa = pairs.filter { $0.ratio >= ContrastGate.aaa.threshold }.count
    let weakest = pairs.min { $0.ratio < $1.ratio }
    let strongest = pairs.max { $0.ratio < $1.ratio }
    let didPass = passing.count == pairs.count

    if json {
        printJSON([
            "file": fileURL.path,
            "gate": gate.rawValue,
            "gateThreshold": gate.threshold,
            "passed": didPass,
            "colors": colors.map(\.hex),
            "pairCount": pairs.count,
            "passingPairCount": passing.count,
            "aaNormalPairCount": aa,
            "aaLargePairCount": large,
            "aaaPairCount": aaa,
            "weakest": pairDictionary(weakest),
            "strongest": pairDictionary(strongest)
        ])
    } else {
        print("PaletteWright audit: \(fileURL.lastPathComponent)")
        print("Gate: \(gate.label) \(String(format: "%.1f", gate.threshold)):1")
        print("Colors: \(colors.count)")
        print("Pairs: \(pairs.count)")
        print(String(format: "Passing gate: %d/%d", passing.count, pairs.count))
        print(String(format: "AA normal: %d/%d", aa, pairs.count))
        print(String(format: "AA large / non-text: %d/%d", large, pairs.count))
        print(String(format: "AAA: %d/%d", aaa, pairs.count))

        if let weakest {
            print(String(format: "Weakest: %@ on %@ %.2f:1", weakest.foreground.hex, weakest.background.hex, weakest.ratio))
        }

        if let strongest {
            print(String(format: "Strongest: %@ on %@ %.2f:1", strongest.foreground.hex, strongest.background.hex, strongest.ratio))
        }
    }

    return didPass ? 0 : 1
}

/// Converts an optional contrast pair into a JSON-friendly dictionary.
func pairDictionary(_ pair: (foreground: RGB, background: RGB, ratio: Double)?) -> [String: Any] {
    guard let pair else {
        return [:]
    }

    return [
        "foreground": pair.foreground.hex,
        "background": pair.background.hex,
        "ratio": Double(String(format: "%.4f", pair.ratio)) ?? pair.ratio
    ]
}

/// Prints a JSON-compatible value as pretty-printed JSON.
func printJSON(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }

    print(string)
}

do {
    let command = try parseCommand(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case .help:
        printUsage()
        exit(0)
    case .audit(let filePath, let gate, let json):
        exit(try runAudit(filePath: filePath, gate: gate, json: json))
    case .extract(let filePath, let json):
        exit(try runExtract(filePath: filePath, json: json))
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n\n", stderr)
    printUsage(to: stderr)
    exit(2)
}
