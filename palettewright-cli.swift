#!/usr/bin/env swift
//
//  palettewright-cli.swift
//  PaletteWright
//
//  Created by Michael Stebel on 5/19/26.
//  Updated by Michael on 5/29/26.
//

import Foundation

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

    /// Creates a color from a normalized six-digit hexadecimal string.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = Int(cleaned, radix: 16) ?? 0
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
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Calculates the WCAG contrast ratio against another RGB color.
    func contrast(with other: RGB) -> Double {
        let first = luminance
        let second = other.luminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

/// Stores one discovered color and where it came from.
struct ColorMatch: Hashable {
    var color: RGB
    var source: String
    var line: Int
    var column: Int

    /// Provides a stable key for deduplicating colors by rendered value.
    var key: String { color.hex }
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
          #RGB, #RGBA, #RRGGBB, #RRGGBBAA, rgb(), rgba(), hsl(), hsla()

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

    var seen: Set<String> = []
    return matches
        .sorted {
            if $0.line != $1.line {
                return $0.line < $1.line
            }
            return $0.column < $1.column
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
                [
                    "hex": $0.color.hex,
                    "source": $0.source,
                    "line": $0.line,
                    "column": $0.column
                ]
            }
        ])
    } else {
        print("PaletteWright extract: \(fileURL.lastPathComponent)")
        print("Colors: \(matches.count)")
        for match in matches {
            print("\(match.color.hex)  \(match.source)  line \(match.line), column \(match.column)")
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

