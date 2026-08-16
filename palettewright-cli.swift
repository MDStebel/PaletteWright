#!/usr/bin/env swift
//
//  palettewright-cli.swift
//  PaletteWright
//
//  Created by Michael Stebel on 5/19/26.
//  Updated by Michael on 8/15/2026
//

import Foundation

let cliVersion = "2.2"

enum RGBSpace: String, Codable {
    case sRGB = "sRGB"
    case displayP3 = "Display-P3"
}

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
    var alpha: Double
    var space: RGBSpace

    /// Creates a color by clamping normalized RGB channels into displayable bounds.
    init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1,
        space: RGBSpace = .sRGB
    ) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
        self.space = space
    }

    /// Creates a color from shorthand, RGB, or RGBA hexadecimal text.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let normalized: String
        switch cleaned.count {
        case 3:
            normalized = String(cleaned.flatMap { [$0, $0] }) + "FF"
        case 4:
            normalized = String(cleaned.flatMap { [$0, $0] })
        case 6:
            normalized = cleaned + "FF"
        case 8:
            normalized = cleaned
        default:
            normalized = cleaned + "FF"
        }

        let value = Int(normalized, radix: 16) ?? 0
        self.init(
            red: Double((value >> 24) & 0xFF) / 255.0,
            green: Double((value >> 16) & 0xFF) / 255.0,
            blue: Double((value >> 8) & 0xFF) / 255.0,
            alpha: Double(value & 0xFF) / 255.0
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
        CLIColorEngine.relativeLuminance(of: self, in: space)
    }

    /// Calculates the WCAG contrast ratio against another RGB color.
    func contrast(with other: RGB) -> Double {
        CLIColorEngine.evaluate(foreground: self, background: other, usage: .normalText).wcagRatio ?? 0
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

enum AccessibilityMethod: String {
    case wcag22
    case apca
    case both

    var label: String {
        switch self {
        case .wcag22: return "WCAG 2.2"
        case .apca: return "APCA"
        case .both: return "WCAG 2.2 + APCA"
        }
    }
}

enum AccessibilityDecision: String {
    case pass
    case fail
    case needsReview = "needsReview"
}

enum AccessibilityUsage: String, Codable {
    case normalText
    case largeText
    case nonTextUI
    case graphic
    case decorative

    func threshold(level: ConformanceLevel) -> Double? {
        switch (self, level) {
        case (.normalText, .aa): return 4.5
        case (.normalText, .aaa): return 7
        case (.largeText, .aa): return 3
        case (.largeText, .aaa): return 4.5
        case (.nonTextUI, .aa), (.graphic, .aa): return 3
        case (.nonTextUI, .aaa), (.graphic, .aaa), (.decorative, _): return nil
        }
    }

    var isText: Bool { self == .normalText || self == .largeText }
}

enum ConformanceLevel: String {
    case aa
    case aaa
}

struct CLIColorEvaluation {
    var decision: AccessibilityDecision
    var reviewReason: String?
    var wcagRatio: Double?
    var wideGamutRatio: Double?
    var apcaLc: Double?
    var apcaFallbackLc: Double?
    var threshold: Double?
    var effectiveForeground: RGB?
    var effectiveBackground: RGB?
}

enum CLIColorEngine {
    static let wcagVersion = "WCAG 2.2 (0.04045)"
    static let apcaLibraryVersion = "apca-w3 0.1.9"
    static let apcaAlgorithmVersion = "0.0.98G-4g"
    static let apcaVersion = "\(apcaLibraryVersion) / \(apcaAlgorithmVersion)"

    static func evaluate(
        foreground: RGB,
        background: RGB,
        usage: AccessibilityUsage,
        level: ConformanceLevel = .aa,
        unsupportedReason: String? = nil
    ) -> CLIColorEvaluation {
        if let unsupportedReason {
            return review(reason: unsupportedReason, threshold: usage.threshold(level: level))
        }
        guard background.alpha >= 1 else {
            return review(
                reason: "The complete alpha layer stack is not known.",
                threshold: usage.threshold(level: level)
            )
        }

        let delivery: RGBSpace = foreground.space == .displayP3 || background.space == .displayP3
            ? .displayP3 : .sRGB
        let deliveryBackground = converted(background, to: delivery).opaque
        let deliveryForeground = composite(converted(foreground, to: delivery), over: deliveryBackground)
        let fallbackBackground = converted(background, to: .sRGB).opaque
        let fallbackForeground = composite(converted(foreground, to: .sRGB), over: fallbackBackground)
        let wideRatio = wcagContrast(deliveryForeground, deliveryBackground, in: delivery)
        let fallbackRatio = wcagContrast(fallbackForeground, fallbackBackground, in: .sRGB)
        let threshold = usage.threshold(level: level)
        let decision: AccessibilityDecision
        if let threshold {
            let ratios = delivery == .displayP3 ? [wideRatio, fallbackRatio] : [fallbackRatio]
            decision = ratios.allSatisfy { $0 >= threshold } ? .pass : .fail
        } else {
            decision = .pass
        }

        return CLIColorEvaluation(
            decision: decision,
            reviewReason: usage == .decorative ? "Decorative color has no WCAG contrast requirement." : nil,
            wcagRatio: fallbackRatio,
            wideGamutRatio: delivery == .displayP3 ? wideRatio : nil,
            apcaLc: apcaContrast(deliveryForeground, deliveryBackground, in: delivery),
            apcaFallbackLc: delivery == .displayP3
                ? apcaContrast(fallbackForeground, fallbackBackground, in: .sRGB) : nil,
            threshold: threshold,
            effectiveForeground: deliveryForeground,
            effectiveBackground: deliveryBackground
        )
    }

    static func relativeLuminance(of color: RGB, in destination: RGBSpace) -> Double {
        let value = converted(color, to: destination)
        let r = linearized(value.red)
        let g = linearized(value.green)
        let b = linearized(value.blue)
        switch destination {
        case .sRGB: return 0.2126 * r + 0.7152 * g + 0.0722 * b
        case .displayP3: return 0.2289745641 * r + 0.6917385218 * g + 0.0792869141 * b
        }
    }

    static func wcagContrast(_ foreground: RGB, _ background: RGB, in space: RGBSpace) -> Double {
        let first = relativeLuminance(of: foreground, in: space)
        let second = relativeLuminance(of: background, in: space)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    static func apcaContrast(_ foreground: RGB, _ background: RGB, in space: RGBSpace) -> Double {
        var textY = apcaY(foreground, in: space)
        var backgroundY = apcaY(background, in: space)
        textY = textY > 0.022 ? textY : textY + pow(0.022 - textY, 1.414)
        backgroundY = backgroundY > 0.022 ? backgroundY : backgroundY + pow(0.022 - backgroundY, 1.414)
        guard abs(backgroundY - textY) >= 0.0005 else { return 0 }

        if backgroundY > textY {
            let raw = (pow(backgroundY, 0.56) - pow(textY, 0.57)) * 1.14
            return raw < 0.1 ? 0 : (raw - 0.027) * 100
        }
        let raw = (pow(backgroundY, 0.65) - pow(textY, 0.62)) * 1.14
        return raw > -0.1 ? 0 : (raw + 0.027) * 100
    }

    static func typographyGuidance(lc: Double, usage: AccessibilityUsage) -> String {
        guard usage.isText else { return "APCA text-readability guidance does not apply to non-text content." }
        switch abs(lc) {
        case 90...: return "Body text: about 16 px/400 or 14 px/700."
        case 75..<90: return "Body text: about 18 px/400 or 14 px/700."
        case 60..<75: return "Large text: about 24 px/400 or 16 px/700."
        case 45..<60: return "Display text: about 42 px/400 or 24 px/700."
        case 30..<45: return "Spot text only; use a much larger or heavier style."
        case 15..<30: return "Non-text or inactive elements only; not readable text."
        default: return "Too little contrast for text guidance."
        }
    }

    static func converted(_ color: RGB, to destination: RGBSpace) -> RGB {
        guard color.space != destination else { return color }
        let r = linearized(color.red)
        let g = linearized(color.green)
        let b = linearized(color.blue)
        let xyz: (x: Double, y: Double, z: Double)
        switch color.space {
        case .sRGB:
            xyz = (
                0.4123907993 * r + 0.3575843394 * g + 0.1804807884 * b,
                0.2126390059 * r + 0.7151686788 * g + 0.0721923154 * b,
                0.0193308187 * r + 0.1191947798 * g + 0.9505321522 * b
            )
        case .displayP3:
            xyz = (
                0.4865709486 * r + 0.2656676932 * g + 0.1982172852 * b,
                0.2289745641 * r + 0.6917385218 * g + 0.0792869141 * b,
                0.0451133819 * g + 1.0439443689 * b
            )
        }
        let linear: (Double, Double, Double)
        switch destination {
        case .sRGB:
            linear = (
                3.2409699419 * xyz.x - 1.5373831776 * xyz.y - 0.4986107603 * xyz.z,
                -0.9692436363 * xyz.x + 1.8759675015 * xyz.y + 0.0415550574 * xyz.z,
                0.0556300797 * xyz.x - 0.2039769589 * xyz.y + 1.0569715142 * xyz.z
            )
        case .displayP3:
            linear = (
                2.4934969119 * xyz.x - 0.9313836179 * xyz.y - 0.4027107845 * xyz.z,
                -0.8294889696 * xyz.x + 1.7626640603 * xyz.y + 0.0236246858 * xyz.z,
                0.0358458302 * xyz.x - 0.0761723893 * xyz.y + 0.9568845240 * xyz.z
            )
        }
        return RGB(
            red: encoded(linear.0),
            green: encoded(linear.1),
            blue: encoded(linear.2),
            alpha: color.alpha,
            space: destination
        )
    }

    static func composite(_ foreground: RGB, over background: RGB) -> RGB {
        guard foreground.alpha < 1 else { return foreground.opaque }
        let bg = converted(background, to: foreground.space)
        return RGB(
            red: foreground.red * foreground.alpha + bg.red * (1 - foreground.alpha),
            green: foreground.green * foreground.alpha + bg.green * (1 - foreground.alpha),
            blue: foreground.blue * foreground.alpha + bg.blue * (1 - foreground.alpha),
            space: foreground.space
        )
    }

    private static func apcaY(_ color: RGB, in destination: RGBSpace) -> Double {
        let value = converted(color, to: destination)
        let r = pow(value.red, 2.4)
        let g = pow(value.green, 2.4)
        let b = pow(value.blue, 2.4)
        switch destination {
        case .sRGB: return 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        case .displayP3: return 0.2289829594805780 * r + 0.6917492625852380 * g + 0.0792677779341829 * b
        }
    }

    private static func review(reason: String, threshold: Double?) -> CLIColorEvaluation {
        CLIColorEvaluation(
            decision: .needsReview,
            reviewReason: reason,
            wcagRatio: nil,
            wideGamutRatio: nil,
            apcaLc: nil,
            apcaFallbackLc: nil,
            threshold: threshold,
            effectiveForeground: nil,
            effectiveBackground: nil
        )
    }

    private static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Double) -> Double {
        let channel = min(max(value, 0), 1)
        return channel <= 0.0031308 ? 12.92 * channel : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }
}

private extension RGB {
    var opaque: RGB { RGB(red: red, green: green, blue: blue, space: space) }
    func withAlpha(_ alpha: Double) -> RGB {
        RGB(red: red, green: green, blue: blue, alpha: alpha, space: space)
    }
    var sourceDescription: String {
        "\(space.rawValue) \(hex) alpha \(String(format: "%.4f", alpha))"
    }
    var serializedCSS: String {
        if space == .displayP3 {
            let alphaSuffix = alpha < 1 ? " / \(String(format: "%.4f", alpha))" : ""
            return "color(display-p3 \(String(format: "%.6f", red)) \(String(format: "%.6f", green)) \(String(format: "%.6f", blue))\(alphaSuffix))"
        }
        if alpha < 1 {
            return hex + String(format: "%02X", Int((alpha * 255).rounded()))
        }
        return hex
    }
}

/// Stores one discovered color and where it came from.
struct ColorMatch: Hashable {
    var color: RGB
    var source: String
    var line: Int
    var column: Int
    var rangeLocation: Int? = nil
    var rangeLength: Int? = nil
    var tokenName: String? = nil

    /// Provides a stable key for deduplicating colors by rendered value.
    var key: String {
        let colorKey = "\(color.space.rawValue)|\(color.hex)|\(String(format: "%.5f", color.alpha))"
        return tokenName.map { "\(normalizedTokenName($0))|\(colorKey)" } ?? colorKey
    }

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
    case audit(filePath: String, gate: ContrastGate, method: AccessibilityMethod, json: Bool)
    case extract(filePath: String, json: Bool)
    case scan(path: String, json: Bool)
    case compile(filePath: String, format: String, outputPath: String)
    case check(
        filePath: String,
        manifestPath: String?,
        level: ConformanceLevel,
        method: AccessibilityMethod,
        allPairs: Bool,
        sarif: Bool,
        json: Bool
    )
    case diff(firstPath: String, secondPath: String, json: Bool)
    case fix(filePath: String, manifestPath: String?, level: ConformanceLevel, outputPath: String?, json: Bool)
    case watch(path: String, format: String, outputPath: String)
    case version
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
    case invalidLevel(String)
    case invalidMethod(String)
    case invalidFormat(String)

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
        case .invalidLevel(let value):
            return "Invalid level '\(value)'. Use aa or aaa."
        case .invalidMethod(let value):
            return "Invalid method '\(value)'. Use wcag22, apca, or both."
        case .invalidFormat(let value):
            return "Invalid format '\(value)'. Use css or json."
        }
    }
}

/// Prints command usage to standard output or standard error.
func printUsage(to stream: UnsafeMutablePointer<FILE> = stdout) {
    fputs(
        """
        PaletteWright CLI

        Usage:
          swift Tools/palettewright-cli.swift audit <file> [--gate aa|aaa|large] [--method wcag22|apca|both] [--json]
          swift Tools/palettewright-cli.swift extract <file> [--json]
          swift Tools/palettewright-cli.swift scan <folder> [--json]
          swift Tools/palettewright-cli.swift compile <file> --format css|json --output <file>
          swift Tools/palettewright-cli.swift check <file> --manifest <pairs.json> [--level aa|aaa] [--method wcag22|apca|both] [--json|--sarif]
          swift Tools/palettewright-cli.swift check <file> --all-pairs [--level aa|aaa] [--json|--sarif]
          swift Tools/palettewright-cli.swift diff <before> <after> [--json]
          swift Tools/palettewright-cli.swift fix <file> --manifest <pairs.json> [--level aa|aaa] [--output <file>] [--json]
          swift Tools/palettewright-cli.swift watch <file-or-folder> --format css|json --output <file>
          swift Tools/palettewright-cli.swift version
          swift Tools/palettewright-cli.swift help

        Commands:
          audit    Explore all extracted pairs with WCAG 2.2 and/or APCA.
          extract  List unique colors discovered in a CSS/JSON/text file.
          scan     Recursively inventory source colors and their locations.
          compile  Produce deterministic CSS or JSON token output.
          check    Gate declared semantic relationships with text, JSON, or SARIF output.
          diff     Compare two token sources by normalized color value.
          fix      Generate manifest-aware repair candidates and relationship impact.
          watch    Recompile whenever a connected file or folder changes.
          version  Print the CLI version.

        Supported color syntax:
          #RGB, #RGBA, #RRGGBB, #RRGGBBAA
          rgb(), rgba(), hsl(), hsla(), hwb()
          lab(), lch(), oklab(), oklch(), color(display-p3 ...)
          JSON hex/RGB/component color objects

        Exit codes:
          0  Command succeeded. For check, every calculated WCAG relationship passed.
          1  Runtime failure or audit/check gate failure.
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
    case "version", "--version", "-v":
        return .version
    case "audit":
        return try parseAuditCommand(Array(arguments.dropFirst()))
    case "extract":
        return try parseExtractCommand(Array(arguments.dropFirst()))
    case "scan":
        return try parseScanCommand(Array(arguments.dropFirst()))
    case "compile":
        return try parseCompileCommand(Array(arguments.dropFirst()), watch: false)
    case "check":
        return try parseCheckCommand(Array(arguments.dropFirst()))
    case "diff":
        return try parseDiffCommand(Array(arguments.dropFirst()))
    case "fix":
        return try parseFixCommand(Array(arguments.dropFirst()))
    case "watch":
        return try parseCompileCommand(Array(arguments.dropFirst()), watch: true)
    default:
        throw CLIError.unknownCommand(command)
    }
}

/// Parses options for the audit command.
func parseAuditCommand(_ arguments: [String]) throws -> Command {
    var filePath: String?
    var gate = ContrastGate.aa
    var method = AccessibilityMethod.wcag22
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
        case "--method":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw CLIError.missingOptionValue(argument)
            }
            guard let parsedMethod = AccessibilityMethod(rawValue: arguments[nextIndex].lowercased()) else {
                throw CLIError.invalidMethod(arguments[nextIndex])
            }
            method = parsedMethod
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

    return .audit(filePath: filePath, gate: gate, method: method, json: json)
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

func parseScanCommand(_ arguments: [String]) throws -> Command {
    var path: String?
    var json = false
    for argument in arguments {
        if argument == "--json" { json = true }
        else if argument.hasPrefix("-") { throw CLIError.unknownOption(argument) }
        else { path = argument }
    }
    guard let path else { throw CLIError.missingFile("scan") }
    return .scan(path: path, json: json)
}

func parseCompileCommand(_ arguments: [String], watch: Bool) throws -> Command {
    var input: String?
    var output: String?
    var format = "css"
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--format" || argument == "--output" {
            guard index + 1 < arguments.count else { throw CLIError.missingOptionValue(argument) }
            if argument == "--format" { format = arguments[index + 1].lowercased() }
            else { output = arguments[index + 1] }
            index += 1
        } else if argument.hasPrefix("-") {
            throw CLIError.unknownOption(argument)
        } else {
            input = argument
        }
        index += 1
    }
    guard ["css", "json"].contains(format) else { throw CLIError.invalidFormat(format) }
    guard let input else { throw CLIError.missingFile(watch ? "watch" : "compile") }
    guard let output else { throw CLIError.missingOptionValue("--output") }
    return watch
        ? .watch(path: input, format: format, outputPath: output)
        : .compile(filePath: input, format: format, outputPath: output)
}

func parseCheckCommand(_ arguments: [String]) throws -> Command {
    var filePath: String?
    var manifestPath: String?
    var level = ConformanceLevel.aa
    var method = AccessibilityMethod.both
    var allPairs = false
    var sarif = false
    var json = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--manifest" {
            guard index + 1 < arguments.count else { throw CLIError.missingOptionValue(argument) }
            manifestPath = arguments[index + 1]
            index += 1
        } else if argument == "--level" {
            guard index + 1 < arguments.count else { throw CLIError.missingOptionValue(argument) }
            guard let value = ConformanceLevel(rawValue: arguments[index + 1].lowercased()) else {
                throw CLIError.invalidLevel(arguments[index + 1])
            }
            level = value
            index += 1
        } else if argument == "--method" {
            guard index + 1 < arguments.count else { throw CLIError.missingOptionValue(argument) }
            guard let value = AccessibilityMethod(rawValue: arguments[index + 1].lowercased()) else {
                throw CLIError.invalidMethod(arguments[index + 1])
            }
            method = value
            index += 1
        } else if argument == "--all-pairs" { allPairs = true }
        else if argument == "--sarif" { sarif = true }
        else if argument == "--json" { json = true }
        else if argument.hasPrefix("-") { throw CLIError.unknownOption(argument) }
        else { filePath = argument }
        index += 1
    }
    guard let filePath else { throw CLIError.missingFile("check") }
    return .check(
        filePath: filePath,
        manifestPath: manifestPath,
        level: level,
        method: method,
        allPairs: allPairs,
        sarif: sarif,
        json: json
    )
}

func parseDiffCommand(_ arguments: [String]) throws -> Command {
    let json = arguments.contains("--json")
    let paths = arguments.filter { !$0.hasPrefix("-") }
    guard paths.count >= 2 else { throw CLIError.missingFile("diff") }
    for argument in arguments where argument.hasPrefix("-") && argument != "--json" {
        throw CLIError.unknownOption(argument)
    }
    return .diff(firstPath: paths[0], secondPath: paths[1], json: json)
}

func parseFixCommand(_ arguments: [String]) throws -> Command {
    var filePath: String?
    var manifestPath: String?
    var level = ConformanceLevel.aa
    var output: String?
    var json = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--output" || argument == "--manifest" || argument == "--level" {
            guard index + 1 < arguments.count else { throw CLIError.missingOptionValue(argument) }
            if argument == "--output" {
                output = arguments[index + 1]
            } else if argument == "--manifest" {
                manifestPath = arguments[index + 1]
            } else if let parsed = ConformanceLevel(rawValue: arguments[index + 1].lowercased()) {
                level = parsed
            } else {
                throw CLIError.invalidLevel(arguments[index + 1])
            }
            index += 1
        } else if argument == "--json" { json = true }
        else if argument.hasPrefix("-") { throw CLIError.unknownOption(argument) }
        else { filePath = argument }
        index += 1
    }
    guard let filePath else { throw CLIError.missingFile("fix") }
    return .fix(filePath: filePath, manifestPath: manifestPath, level: level, outputPath: output, json: json)
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

    matches = matches.map { match in
        var annotated = match
        annotated.tokenName = inferredTokenName(atLine: match.line, column: match.column, in: text)
        return annotated
    }

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
        let location = lineColumn(for: range.location, in: text)
        return ColorMatch(
            color: RGB(hex: raw),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
        )
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
            color: RGB(
                red: red,
                green: green,
                blue: blue,
                alpha: components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1
            ),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
            color: rgbFromHSL(hue: hue, saturation: saturation, lightness: lightness)
                .withAlpha(components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
            color: rgbFromHWB(hue: hue, whiteness: whiteness, blackness: blackness)
                .withAlpha(components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
            color: RGB.fromCIELab(CIELab(lightness: lightness, a: a, b: b))
                .withAlpha(components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
            color: RGB.fromCIELCH(CIELCH(lightness: lightness, chroma: chroma, hueDegrees: hue))
                .withAlpha(components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
            color: RGB.fromOKLab(OKLab(lightness: lightness, a: a, b: b))
                .withAlpha(components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
            color: RGB.fromOKLCH(OKLCH(lightness: lightness, chroma: chroma, hueDegrees: hue))
                .withAlpha(components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
            color: RGB(
                red: red,
                green: green,
                blue: blue,
                alpha: components.count > 3 ? (unitIntervalValue(from: components[3]) ?? 1) : 1,
                space: .displayP3
            ),
            source: raw,
            line: location.line,
            column: location.column,
            rangeLocation: range.location,
            rangeLength: range.length
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
        let values = [red, green, blue].map { abs($0) > 1 ? $0 / 255 : $0 }
        let spaceName = stringValue(dictionary["colorSpace"] ?? dictionary["space"] ?? dictionary["model"])?.lowercased() ?? "srgb"
        return JSONColorHit(
            color: RGB(
                red: values[0],
                green: values[1],
                blue: values[2],
                alpha: numericValue(dictionary["alpha"] ?? dictionary["opacity"]) ?? 1,
                space: spaceName.contains("p3") ? .displayP3 : .sRGB
            ),
            source: "JSON RGB components"
        )
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
    let alpha = numericValue(dictionary["alpha"] ?? dictionary["opacity"])
        ?? (numbers.count > 3 ? numbers[3] : 1)

    if space.contains("oklch") {
        return JSONColorHit(
            color: RGB.fromOKLCH(OKLCH(lightness: numbers[0], chroma: numbers[1], hueDegrees: numbers[2]))
                .withAlpha(alpha),
            source: "JSON OKLCH components"
        )
    }

    if space.contains("oklab") {
        return JSONColorHit(
            color: RGB.fromOKLab(OKLab(lightness: numbers[0], a: numbers[1], b: numbers[2]))
                .withAlpha(alpha),
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
            ).withAlpha(alpha),
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
            ).withAlpha(alpha),
            source: "JSON Lab components"
        )
    }

    let values = Array(numbers.prefix(3)).map { abs($0) > 1 ? $0 / 255 : $0 }
    return JSONColorHit(
        color: RGB(
            red: values[0],
            green: values[1],
            blue: values[2],
            alpha: alpha,
            space: space.contains("p3") ? .displayP3 : .sRGB
        ),
        source: "JSON RGB components"
    )
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

func normalizedTokenName(_ value: String) -> String {
    value
        .replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1-$2",
            options: .regularExpression
        )
        .lowercased()
        .replacingOccurrences(of: "--", with: "")
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: ".", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func inferredTokenName(atLine line: Int, column: Int, in text: String) -> String? {
    guard line > 0 else { return nil }
    let lines = text.components(separatedBy: .newlines)
    guard lines.indices.contains(line - 1) else { return nil }
    let currentLine = lines[line - 1]
    let prefix = String(currentLine.prefix(max(column - 1, 0)))
    let patterns = [
        #"(--[A-Za-z0-9_-]+)\s*:\s*$"#,
        #"[\"']([^\"']+)[\"']\s*:\s*[\"']?\s*$"#,
        #"(?:let|var|const)\s+([A-Za-z_$][A-Za-z0-9_$]*)[^=]*=\s*[\"']?\s*$"#,
        #"([A-Za-z_$][A-Za-z0-9_$.-]*)\s*:\s*[\"']?\s*$"#,
        #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*[\"']?\s*$"#
    ]
    for pattern in patterns {
        if let name = firstCapture(pattern: pattern, in: prefix) {
            return name
        }
    }
    return nil
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

struct SemanticPairManifest: Codable {
    var foreground: String
    var background: String
    var usage: AccessibilityUsage
    var modes: [String]?
    var states: [String]?
    var unsupportedContext: String?
}

private struct SemanticManifestDocument: Codable {
    var pairs: [SemanticPairManifest]
}

struct SemanticFinding {
    var pair: SemanticPairManifest
    var mode: String
    var state: String
    var foreground: ColorMatch?
    var background: ColorMatch?
    var evaluation: CLIColorEvaluation

    var id: String {
        "\(pair.foreground)-on-\(pair.background)-\(mode)-\(state)-\(pair.usage.rawValue)"
    }
}

func readSemanticManifest(at path: String) throws -> [SemanticPairManifest] {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        throw CLIError.unreadableFile(url.path)
    }
    let decoder = JSONDecoder()
    if let document = try? decoder.decode(SemanticManifestDocument.self, from: data) {
        return document.pairs
    }
    if let pairs = try? decoder.decode([SemanticPairManifest].self, from: data) {
        return pairs
    }
    if let pair = try? decoder.decode(SemanticPairManifest.self, from: data) {
        return [pair]
    }
    throw CLIError.unreadableFile("\(url.path) (invalid semantic pair manifest)")
}

func resolveToken(
    _ reference: String,
    mode: String,
    matches: [ColorMatch]
) -> ColorMatch? {
    let referenceName = normalizedTokenName(reference)
    let modeName = normalizedTokenName(mode)
    let candidates = matches.filter { $0.tokenName != nil }
    let modeNames: [String]
    switch modeName {
    case "increased-contrast": modeNames = ["increased-contrast", "high-contrast"]
    case "high-contrast": modeNames = ["high-contrast", "increased-contrast"]
    default: modeNames = [modeName]
    }
    let names = modeNames.flatMap { modeName in
        ["\(modeName)-\(referenceName)", "\(referenceName)-\(modeName)"]
    } + [referenceName]

    for name in names {
        let exact = candidates.filter { normalizedTokenName($0.tokenName ?? "") == name }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            return exact.sorted { ($0.line, $0.column) < ($1.line, $1.column) }.first
        }
    }

    let suffix = candidates.filter {
        let token = normalizedTokenName($0.tokenName ?? "")
        return token.hasSuffix("-\(referenceName)") || referenceName.hasSuffix("-\(token)")
    }
    return suffix.count == 1 ? suffix[0] : nil
}

func semanticFindings(
    matches: [ColorMatch],
    manifest: [SemanticPairManifest],
    level: ConformanceLevel
) -> [SemanticFinding] {
    manifest.flatMap { pair -> [SemanticFinding] in
        let modes = pair.modes?.isEmpty == false ? pair.modes! : ["default"]
        let states = pair.states?.isEmpty == false ? pair.states! : ["default"]
        return modes.flatMap { mode in
            states.map { state in
                let foreground = resolveToken(pair.foreground, mode: mode, matches: matches)
                let background = resolveToken(pair.background, mode: mode, matches: matches)
                let unresolved = foreground == nil || background == nil
                    ? "A declared token or variable could not be resolved."
                    : nil
                let evaluation: CLIColorEvaluation
                if let foreground, let background {
                    evaluation = CLIColorEngine.evaluate(
                        foreground: foreground.color,
                        background: background.color,
                        usage: pair.usage,
                        level: level,
                        unsupportedReason: pair.unsupportedContext ?? unresolved
                    )
                } else {
                    evaluation = CLIColorEngine.evaluate(
                        foreground: RGB(hex: "#000000"),
                        background: RGB(hex: "#FFFFFF"),
                        usage: pair.usage,
                        level: level,
                        unsupportedReason: pair.unsupportedContext ?? unresolved
                    )
                }
                return SemanticFinding(
                    pair: pair,
                    mode: mode,
                    state: state,
                    foreground: foreground,
                    background: background,
                    evaluation: evaluation
                )
            }
        }
    }
}

func allPairFindings(
    matches: [ColorMatch],
    level: ConformanceLevel,
    usage: AccessibilityUsage = .normalText
) -> [SemanticFinding] {
    matches.flatMap { foreground in
        matches.filter { $0.key != foreground.key }.map { background in
            let pair = SemanticPairManifest(
                foreground: foreground.tokenName ?? foreground.color.hex,
                background: background.tokenName ?? background.color.hex,
                usage: usage,
                modes: ["exploratory"],
                states: ["default"],
                unsupportedContext: nil
            )
            return SemanticFinding(
                pair: pair,
                mode: "exploratory",
                state: "default",
                foreground: foreground,
                background: background,
                evaluation: CLIColorEngine.evaluate(
                    foreground: foreground.color,
                    background: background.color,
                    usage: usage,
                    level: level
                )
            )
        }
    }
}

func findingDictionary(_ finding: SemanticFinding) -> [String: Any] {
    let evaluation = finding.evaluation
    var value: [String: Any] = [
        "id": finding.id,
        "foregroundToken": finding.pair.foreground,
        "backgroundToken": finding.pair.background,
        "usage": finding.pair.usage.rawValue,
        "mode": finding.mode,
        "state": finding.state,
        "decision": evaluation.decision.rawValue,
        "sourceColorSpace": [finding.foreground?.color.space.rawValue, finding.background?.color.space.rawValue]
            .compactMap { $0 }.joined(separator: " / "),
        "sourceForeground": finding.foreground?.color.sourceDescription ?? NSNull(),
        "sourceBackground": finding.background?.color.sourceDescription ?? NSNull(),
        "effectiveForeground": evaluation.effectiveForeground?.sourceDescription ?? NSNull(),
        "effectiveBackground": evaluation.effectiveBackground?.sourceDescription ?? NSNull(),
        "wcagRawResult": evaluation.wcagRatio ?? NSNull(),
        "wcagWideGamutRawResult": evaluation.wideGamutRatio ?? NSNull(),
        "threshold": evaluation.threshold ?? NSNull(),
        "apcaSignedLc": evaluation.apcaLc ?? NSNull(),
        "apcaSRGBFallbackSignedLc": evaluation.apcaFallbackLc ?? NSNull(),
        "method": CLIColorEngine.wcagVersion,
        "decisionBasis": CLIColorEngine.wcagVersion,
        "apcaMethod": CLIColorEngine.apcaVersion,
        "reviewReason": evaluation.reviewReason ?? NSNull(),
        "foregroundLocation": finding.foreground?.locationDictionary ?? [:],
        "backgroundLocation": finding.background?.locationDictionary ?? [:]
    ]
    if let lc = evaluation.apcaLc {
        value["apcaTypographyGuidance"] = CLIColorEngine.typographyGuidance(lc: lc, usage: finding.pair.usage)
    }
    return value
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
func runAudit(
    filePath: String,
    gate: ContrastGate,
    method: AccessibilityMethod,
    json: Bool
) throws -> Int32 {
    let (fileURL, text) = try readTextFile(at: filePath)
    let matches = extractColorMatches(from: text)

    guard matches.count >= 2 else {
        if json {
            printJSON([
                "file": fileURL.path,
                "colors": matches.count,
                "error": "Need at least 2 colors to audit contrast."
            ])
        } else {
            print("Found \(matches.count) color. Need at least 2 colors to audit contrast.")
        }
        return 1
    }

    let usage: AccessibilityUsage = gate == .large ? .largeText : .normalText
    let level: ConformanceLevel = gate == .aaa ? .aaa : .aa
    let findings = allPairFindings(matches: matches, level: level, usage: usage)
    let passing = findings.filter { $0.evaluation.decision == .pass }.count
    let failing = findings.filter { $0.evaluation.decision == .fail }.count
    let review = findings.filter { $0.evaluation.decision == .needsReview }.count
    let calculated = findings.compactMap { finding -> (SemanticFinding, Double)? in
        finding.evaluation.wcagRatio.map { (finding, $0) }
    }
    let weakest = calculated.min { $0.1 < $1.1 }
    let strongest = calculated.max { $0.1 < $1.1 }
    let didPass = (method == .apca || failing == 0) && review == 0

    if json {
        printJSON([
            "toolVersion": cliVersion,
            "file": fileURL.path,
            "exploratory": true,
            "method": method.label,
            "wcagMethodVersion": CLIColorEngine.wcagVersion,
            "apcaMethodVersion": CLIColorEngine.apcaVersion,
            "apcaStatus": "supplemental / experimental; no WCAG 3 conformance claim",
            "gate": gate.rawValue,
            "gateThreshold": gate.threshold,
            "passed": didPass,
            "wcagGatePassed": failing == 0 && review == 0,
            "colors": matches.map { $0.color.sourceDescription },
            "pairCount": findings.count,
            "passingPairCount": passing,
            "failingPairCount": failing,
            "needsReviewPairCount": review,
            "weakest": weakest.map { findingDictionary($0.0) } ?? [:],
            "strongest": strongest.map { findingDictionary($0.0) } ?? [:],
            "relationships": findings.map(findingDictionary)
        ])
    } else {
        print("PaletteWright audit: \(fileURL.lastPathComponent)")
        print("Exploratory all-pairs mode (not the semantic conformance gate)")
        print("Method: \(method.label)")
        print("WCAG: \(CLIColorEngine.wcagVersion)")
        if method != .wcag22 { print("APCA: \(CLIColorEngine.apcaVersion) — supplemental / experimental") }
        print("Gate: \(gate.label) \(String(format: "%.1f", gate.threshold)):1")
        print("Colors: \(matches.count)")
        print("Pairs: \(findings.count)")
        print("WCAG decisions — Pass: \(passing) · Fail: \(failing) · Needs review: \(review)")
        if let weakest { print(String(format: "Weakest: %@ %.4f:1", weakest.0.id, weakest.1)) }
        if let strongest { print(String(format: "Strongest: %@ %.4f:1", strongest.0.id, strongest.1)) }
    }

    return didPass ? 0 : 1
}

func readableSourceFiles(at path: String) throws -> [(URL, String)] {
    let root = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
        throw CLIError.unreadableFile(root.path)
    }
    if !isDirectory.boolValue { return [try readTextFile(at: root.path)] }
    let extensions = Set(["css", "scss", "sass", "less", "json", "jsonc", "tokens", "swift", "js", "jsx", "ts", "tsx", "html", "xml", "txt", "md"])
    let urls = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
    let recursive = (enumerator?.allObjects as? [URL]) ?? urls
    return recursive
        .filter { extensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.path < $1.path }
        .compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url, text)
        }
}

func uniqueColors(in files: [(URL, String)]) -> [RGB] {
    Array(Set(files.flatMap { extractColorMatches(from: $0.1).map(\.color) })).sorted { $0.hex < $1.hex }
}

/// Returns a stable path relative to the scan root, even when macOS resolves a
/// path component through a symlink (for example, `/tmp` to `/private/tmp`).
func scanRelativePath(for fileURL: URL, rootURL: URL) -> String {
    let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let fileComponents = resolvedFileURL.pathComponents
    let rootComponents = resolvedRootURL.pathComponents

    guard fileComponents.count >= rootComponents.count,
          Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
        return resolvedFileURL.path
    }

    let relativeComponents = fileComponents.dropFirst(rootComponents.count)
    return relativeComponents.isEmpty
        ? resolvedFileURL.lastPathComponent
        : relativeComponents.joined(separator: "/")
}

func runScan(path: String, json: Bool) throws -> Int32 {
    let root = URL(fileURLWithPath: path).standardizedFileURL
    let files = try readableSourceFiles(at: path)
    let rows: [[String: Any]] = files.flatMap { url, text in
        extractColorMatches(from: text).map { match in
            [
                "file": scanRelativePath(for: url, rootURL: root),
                "hex": match.color.hex,
                "source": match.source,
                "line": match.line,
                "column": match.column
            ]
        }
    }
    if json {
        printJSON(["root": root.path, "fileCount": files.count, "matchCount": rows.count, "colors": rows])
    } else {
        print("PaletteWright scan: \(root.path)")
        print("Files: \(files.count) · Color matches: \(rows.count)")
        for row in rows {
            print("\(row["hex"] ?? "")  \(row["file"] ?? ""):\(row["line"] ?? 0):\(row["column"] ?? 0)")
        }
    }
    return rows.isEmpty ? 1 : 0
}

func compiledText(colors: [RGB], format: String) -> String {
    if format == "json" {
        let values = Dictionary(uniqueKeysWithValues: colors.enumerated().map { index, color in
            (String(format: "color-%03d", index + 1), color.hex)
        })
        guard let data = try? JSONSerialization.data(withJSONObject: ["color": values], options: [.prettyPrinted, .sortedKeys]) else { return "{}\n" }
        return String(data: data, encoding: .utf8)! + "\n"
    }
    let rows = colors.enumerated().map { index, color in
        "  --color-\(String(format: "%03d", index + 1)): \(color.hex);"
    }
    return ([":root {"] + rows + ["}", ""]).joined(separator: "\n")
}

@discardableResult
func runCompile(filePath: String, format: String, outputPath: String) throws -> Int32 {
    let files = try readableSourceFiles(at: filePath)
    let colors = uniqueColors(in: files)
    guard !colors.isEmpty else { return 1 }
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try compiledText(colors: colors, format: format).write(to: outputURL, atomically: true, encoding: .utf8)
    print("Compiled \(colors.count) deterministic tokens to \(outputURL.path)")
    return 0
}

func runCheck(
    filePath: String,
    manifestPath: String?,
    level: ConformanceLevel,
    method: AccessibilityMethod,
    allPairs: Bool,
    sarif: Bool,
    json: Bool
) throws -> Int32 {
    let (url, text) = try readTextFile(at: filePath)
    let matches = extractColorMatches(from: text)
    let findings: [SemanticFinding]
    if allPairs {
        findings = allPairFindings(matches: matches, level: level)
    } else if let manifestPath {
        findings = semanticFindings(
            matches: matches,
            manifest: try readSemanticManifest(at: manifestPath),
            level: level
        )
    } else {
        let pair = SemanticPairManifest(
            foreground: "unresolved",
            background: "unresolved",
            usage: .normalText,
            modes: ["default"],
            states: ["default"],
            unsupportedContext: "No semantic pair manifest was supplied. Use --manifest or explicit --all-pairs exploration."
        )
        findings = semanticFindings(matches: matches, manifest: [pair], level: level)
    }
    let failed = findings.filter { $0.evaluation.decision == .fail }
    let review = findings.filter { $0.evaluation.decision == .needsReview }
    let passed = findings.filter { $0.evaluation.decision == .pass }
    let normativeFailures = method == .apca ? 0 : failed.count
    let completedWithoutReview = normativeFailures == 0 && review.isEmpty

    if sarif {
        let results: [[String: Any]] = (method == .apca ? review : failed + review).map { finding in
            let needsReview = finding.evaluation.decision == .needsReview
            let primary = finding.foreground ?? finding.background
            let secondary = finding.background
            let locations = [primary, secondary].compactMap { match -> [String: Any]? in
                guard let match else { return nil }
                return [
                    "physicalLocation": [
                        "artifactLocation": ["uri": url.path],
                        "region": ["startLine": max(match.line, 1), "startColumn": max(match.column, 1)]
                    ]
                ]
            }
            return [
                "ruleId": needsReview ? "PW002" : "PW001",
                "level": needsReview ? "warning" : "error",
                "message": [
                    "text": needsReview
                        ? "\(finding.id) needs review: \(finding.evaluation.reviewReason ?? "runtime context is unknown")"
                        : "\(finding.id) fails \(level.rawValue.uppercased()) at raw ratio \(finding.evaluation.wcagRatio ?? 0)."
                ],
                "locations": locations,
                "properties": findingDictionary(finding)
            ]
        }
        printJSON([
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "version": "2.1.0",
            "runs": [[
                "tool": ["driver": [
                    "name": "PaletteWright",
                    "version": cliVersion,
                    "informationUri": "https://palettewright.com",
                    "rules": [
                        ["id": "PW001", "shortDescription": ["text": "Declared relationship fails WCAG contrast"]],
                        ["id": "PW002", "shortDescription": ["text": "Declared relationship needs rendered or human review"]]
                    ]
                ]],
                "results": results
            ]]
        ])
    } else if json {
        printJSON([
            "tool": "PaletteWright",
            "toolVersion": cliVersion,
            "file": url.path,
            "manifest": (manifestPath as Any?) ?? NSNull(),
            "exploratoryAllPairs": allPairs,
            "level": level.rawValue,
            "method": method.label,
            "wcagMethodVersion": CLIColorEngine.wcagVersion,
            "apcaMethodVersion": CLIColorEngine.apcaVersion,
            "apcaStatus": "supplemental / experimental; no WCAG 3 conformance claim",
            "passed": completedWithoutReview,
            "wcagGatePassed": failed.isEmpty && review.isEmpty,
            "summary": ["pass": passed.count, "fail": failed.count, "needsReview": review.count],
            "relationships": findings.map(findingDictionary)
        ])
    } else {
        print("PaletteWright semantic check: \(url.lastPathComponent)")
        print("Method: \(method.label) · Level: \(level.rawValue.uppercased())")
        print("WCAG: \(CLIColorEngine.wcagVersion)")
        if method != .wcag22 { print("APCA: \(CLIColorEngine.apcaVersion) — supplemental / experimental") }
        print("WCAG decisions — Pass: \(passed.count) · Fail: \(failed.count) · Needs review: \(review.count)")
        for finding in findings {
            let ratio = finding.evaluation.wcagRatio.map { String(format: "%.4f:1", $0) } ?? "n/a"
            let lc = finding.evaluation.apcaLc.map { String(format: "%+.2f Lc", $0) } ?? "n/a"
            print("\(finding.evaluation.decision.rawValue.uppercased())  \(finding.id)  WCAG \(ratio)  APCA \(lc)")
            if let reason = finding.evaluation.reviewReason { print("  \(reason)") }
        }
    }

    return completedWithoutReview ? 0 : 1
}

func runDiff(firstPath: String, secondPath: String, json: Bool) throws -> Int32 {
    let before = Set(uniqueColors(in: try readableSourceFiles(at: firstPath)).map(\.hex))
    let after = Set(uniqueColors(in: try readableSourceFiles(at: secondPath)).map(\.hex))
    let added = Array(after.subtracting(before)).sorted()
    let removed = Array(before.subtracting(after)).sorted()
    if json { printJSON(["added": added, "removed": removed, "changed": !added.isEmpty || !removed.isEmpty]) }
    else {
        print("PaletteWright diff")
        for color in added { print("+ \(color)") }
        for color in removed { print("- \(color)") }
        if added.isEmpty && removed.isEmpty { print("No normalized color changes.") }
    }
    return added.isEmpty && removed.isEmpty ? 0 : 1
}

func accessibleRepairCandidate(_ foreground: RGB, on background: RGB, target: Double) -> RGB {
    func minimumDeliveryRatio(_ candidate: RGB) -> Double {
        let evaluation = CLIColorEngine.evaluate(
            foreground: candidate,
            background: background,
            usage: .normalText
        )
        return [evaluation.wcagRatio, evaluation.wideGamutRatio].compactMap { $0 }.min() ?? 0
    }

    if minimumDeliveryRatio(foreground) >= target {
        return foreground
    }

    let sRGBForeground = CLIColorEngine.converted(foreground, to: .sRGB)
    let sRGBBackground = CLIColorEngine.converted(background, to: .sRGB).opaque

    let original = sRGBForeground.okLCH
    let shouldLighten = CLIColorEngine.relativeLuminance(of: sRGBBackground, in: .sRGB) < 0.5
    let targetLightness = shouldLighten ? 0.98 : 0.06
    for step in 1...96 {
        let amount = Double(step) / 96
        let sRGBCandidate = RGB.fromOKLCH(
            OKLCH(
                lightness: original.lightness + (targetLightness - original.lightness) * amount,
                chroma: original.chroma * (1 - amount * 0.34),
                hueDegrees: original.hueDegrees
            )
        ).withAlpha(foreground.alpha)
        let candidate = CLIColorEngine.converted(sRGBCandidate, to: foreground.space)
        if minimumDeliveryRatio(candidate) >= target {
            return candidate
        }
    }
    let black = CLIColorEngine.converted(RGB(hex: "#050505").withAlpha(foreground.alpha), to: foreground.space)
    let white = CLIColorEngine.converted(RGB(hex: "#FFFFFF").withAlpha(foreground.alpha), to: foreground.space)
    return minimumDeliveryRatio(black) >= minimumDeliveryRatio(white) ? black : white
}

func runFix(
    filePath: String,
    manifestPath: String?,
    level: ConformanceLevel,
    outputPath: String?,
    json: Bool
) throws -> Int32 {
    let (url, text) = try readTextFile(at: filePath)
    let matches = extractColorMatches(from: text)
    guard let manifestPath else {
        if json {
            printJSON([
                "file": url.path,
                "decision": AccessibilityDecision.needsReview.rawValue,
                "reviewReason": "A semantic pair manifest is required for repair."
            ])
        } else {
            print("PaletteWright fix needs a semantic pair manifest. Pass --manifest <pairs.json>.")
        }
        return 1
    }
    let manifest = try readSemanticManifest(at: manifestPath)
    let before = semanticFindings(matches: matches, manifest: manifest, level: level)
    let failing = before.filter { $0.evaluation.decision == .fail }
    var replacementDescriptions: [String: String] = [:]
    var replacementsByLocation: [Int: (length: Int, value: String)] = [:]
    var candidatesByLocation: [Int: RGB] = [:]
    for finding in failing {
        guard let foreground = finding.foreground,
              let background = finding.background,
              let threshold = finding.evaluation.threshold,
              let location = foreground.rangeLocation,
              let length = foreground.rangeLength else { continue }
        let candidate = accessibleRepairCandidate(foreground.color, on: background.color, target: threshold)
        let label = "\(foreground.tokenName ?? foreground.source) @ \(foreground.locationDescription)"
        replacementDescriptions[label] = "\(foreground.source) -> \(candidate.serializedCSS)"
        replacementsByLocation[location] = (length: length, value: candidate.serializedCSS)
        candidatesByLocation[location] = candidate
    }

    let revisedMatches = matches.map { match -> ColorMatch in
        guard let location = match.rangeLocation,
              let candidate = candidatesByLocation[location] else { return match }
        var revised = match
        revised.color = candidate
        return revised
    }
    let after = semanticFindings(matches: revisedMatches, manifest: manifest, level: level)
    let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    let improved = before.filter {
        $0.evaluation.decision == .fail && afterByID[$0.id]?.evaluation.decision == .pass
    }.map(\.id)
    let broken = before.filter {
        $0.evaluation.decision == .pass && afterByID[$0.id]?.evaluation.decision == .fail
    }.map(\.id)
    let afterFailureCount = after.filter { $0.evaluation.decision == .fail }.count

    if let outputPath {
        let repaired = NSMutableString(string: text)
        for (location, replacement) in replacementsByLocation.sorted(by: { $0.key > $1.key }) {
            let range = NSRange(location: location, length: replacement.length)
            guard NSMaxRange(range) <= repaired.length else { continue }
            repaired.replaceCharacters(in: range, with: replacement.value)
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (repaired as String).write(to: outputURL, atomically: true, encoding: .utf8)
    }
    if json {
        printJSON([
            "file": url.path,
            "manifest": manifestPath,
            "level": level.rawValue,
            "method": CLIColorEngine.wcagVersion,
            "replacements": replacementDescriptions,
            "relationshipsImproved": improved,
            "relationshipsBroken": broken,
            "beforeFailureCount": failing.count,
            "afterFailureCount": afterFailureCount,
            "output": (outputPath as Any?) ?? NSNull()
        ])
    }
    else {
        print("PaletteWright manifest-aware fix: \(replacementDescriptions.count) suggested replacement(s)")
        for key in replacementDescriptions.keys.sorted() { print("\(key): \(replacementDescriptions[key]!)") }
        print("Relationships improved: \(improved.count) · broken: \(broken.count)")
        if !broken.isEmpty { print("Review regressions: \(broken.joined(separator: ", "))") }
    }
    return broken.isEmpty && afterFailureCount == 0 ? 0 : 1
}

func runWatch(path: String, format: String, outputPath: String) throws -> Int32 {
    var lastSignature = ""
    print("Watching \(path). Press Control-C to stop.")
    while true {
        let files = try readableSourceFiles(at: path)
        let signature = files.map { "\($0.0.path):\($0.1.hashValue)" }.joined(separator: "|")
        if signature != lastSignature {
            lastSignature = signature
            _ = try runCompile(filePath: path, format: format, outputPath: outputPath)
        }
        Thread.sleep(forTimeInterval: 0.75)
    }
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

/// Prints the CLI version.
func printVersion() {
    print("PaletteWright CLI \(cliVersion)")
}

do {
    let command = try parseCommand(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case .help:
        printUsage()
        exit(0)
    case .version:
        printVersion()
        exit(0)
    case .audit(let filePath, let gate, let method, let json):
        exit(try runAudit(filePath: filePath, gate: gate, method: method, json: json))
    case .extract(let filePath, let json):
        exit(try runExtract(filePath: filePath, json: json))
    case .scan(let path, let json):
        exit(try runScan(path: path, json: json))
    case .compile(let filePath, let format, let outputPath):
        exit(try runCompile(filePath: filePath, format: format, outputPath: outputPath))
    case .check(let filePath, let manifestPath, let level, let method, let allPairs, let sarif, let json):
        exit(try runCheck(
            filePath: filePath,
            manifestPath: manifestPath,
            level: level,
            method: method,
            allPairs: allPairs,
            sarif: sarif,
            json: json
        ))
    case .diff(let firstPath, let secondPath, let json):
        exit(try runDiff(firstPath: firstPath, secondPath: secondPath, json: json))
    case .fix(let filePath, let manifestPath, let level, let outputPath, let json):
        exit(try runFix(
            filePath: filePath,
            manifestPath: manifestPath,
            level: level,
            outputPath: outputPath,
            json: json
        ))
    case .watch(let path, let format, let outputPath):
        exit(try runWatch(path: path, format: format, outputPath: outputPath))
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n\n", stderr)
    printUsage(to: stderr)
    exit(2)
}
