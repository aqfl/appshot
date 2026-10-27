#!/usr/bin/env swift
// appshot — clean or "marketing-ready" screenshots of a running macOS app window.
//
// Usage:
//   ./appshot.swift <AppName> [options]
//
// Options:
//   -o, --out <file>      Output PNG (default: <AppName>-screenshot.png)
//   --clean               Just the window, no background (transparent corners, no shadow)
//   --bg <spec>           Default: gold. One of:
//                           preset gradient  gold, aqua, sunset, purple, graphite
//                           mesh gradient    sunrise, bubblegum, pastel, cosmic, cosmic-warm, mystic,
//                                            midnight, goldglow
//                           ribbed glass     glass-orange, glass-blue, glass-fire
//                           "#hex,#hex,#hex" custom linear gradient, or a single "#hex"
//                           wallpaper        your current macOS desktop picture
//                           macos:<name>     a built-in macOS wallpaper, e.g. macos:sequoia
//                           /path/to/image   any image (aspect-fill)
//   --size WxH            Canvas size in px (default 2880x1800, the Mac App Store 16:10 size)
//   --pad <0-0.4>         Padding around the window as a fraction of canvas (default 0.08)
//   --tight               Mostly app, minimal background: pad 0.04 and scale the window up to fill
//                         (a later --pad overrides the padding)
//   --title <text>        Only match windows whose title contains this text
//   --delay <sec>         Wait after activating the app (default 0.8)
//   --upscale             Allow scaling the window UP to fill the canvas (default: never upscale)
//   --no-activate         Don't bring the app to front first
//   --list                List on-screen windows and exit
//   --list-bgs            List available background presets and built-in macOS wallpapers
//
// Needs: Xcode command line tools (swift). Terminal needs Screen Recording permission
// (System Settings > Privacy & Security > Screen & System Audio Recording).
//
// Faster startup:  swiftc -O appshot.swift -o appshot

import Foundation
import CoreGraphics
import ImageIO
import AppKit

// MARK: - Args

struct Opts {
    var app = ""
    var out: String?
    var clean = false
    var bg = "gold"
    var w = 2880
    var h = 1800
    var pad = 0.08
    var title: String?
    var delay = 0.8
    var upscale = false
    var activate = true
    var list = false
    var listBgs = false
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func parseArgs() -> Opts {
    var o = Opts()
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { die("Missing value for \(flag)") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-o", "--out": o.out = next(a)
        case "--clean": o.clean = true
        case "--bg": o.bg = next(a)
        case "--size":
            let parts = next(a).lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { die("--size expects WxH, e.g. 2880x1800") }
            o.w = parts[0]; o.h = parts[1]
        case "--pad": o.pad = min(0.4, max(0, Double(next(a)) ?? 0.08))
        case "--tight": o.pad = 0.04; o.upscale = true
        case "--title": o.title = next(a)
        case "--delay": o.delay = Double(next(a)) ?? 0.8
        case "--upscale": o.upscale = true
        case "--no-activate": o.activate = false
        case "--list": o.list = true
        case "--list-bgs": o.listBgs = true
        case "-h", "--help":
            print("Usage: appshot <AppName> [--out f.png] [--clean] [--bg <preset>|wallpaper|macos:<name>|#hex,#hex|image] [--size WxH] [--pad 0.08] [--tight] [--title text] [--delay s] [--upscale] [--no-activate] [--list] [--list-bgs]")
            exit(0)
        default:
            if a.hasPrefix("-") { die("Unknown option \(a)") }
            o.app = a
        }
    }
    return o
}

// MARK: - Window lookup

struct Win { let id: CGWindowID; let owner: String; let title: String; let rect: CGRect }

func onScreenWindows() -> [Win] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return [] }
    var result: [Win] = []
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String,
              let num = w[kCGWindowNumber as String] as? Int,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
        let title = (w[kCGWindowName as String] as? String) ?? ""
        result.append(Win(id: CGWindowID(num), owner: owner, title: title, rect: rect))
    }
    return result
}

func findWindow(app: String, title: String?) -> Win? {
    let needle = app.lowercased()
    return onScreenWindows()
        .filter { $0.owner.lowercased().contains(needle) && $0.rect.width > 100 && $0.rect.height > 100 }
        .filter { title == nil || $0.title.lowercased().contains(title!.lowercased()) }
        .max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
}

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Colors & backgrounds

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    let v = UInt32(s, radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255,
                   green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: alpha)
}

let presets: [String: [String]] = [
    "gold":     ["#0a0a0a", "#1c1608", "#c9a24b"],
    "aqua":     ["#0f2027", "#2c7a8c", "#9be7d8"],
    "sunset":   ["#2b1055", "#d4417a", "#ffb36b"],
    "purple":   ["#1a0b3b", "#5b2bd6", "#b58cff"],
    "graphite": ["#16181d", "#2b3038", "#4a5160"],
]

func loadImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// A "mesh" gradient: a base color plus soft radial color blobs.
// Blob coords are 0...1 with (0,0) = top-left; radius is a fraction of canvas width.
struct Blob {
    let x: CGFloat, y: CGFloat, r: CGFloat, hex: String, a: CGFloat
    init(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: String, _ a: CGFloat = 1) {
        self.x = x; self.y = y; self.r = r; self.hex = hex; self.a = a
    }
}
struct Mesh { let base: String; let blobs: [Blob]; var ribbed = false }

let meshes: [String: Mesh] = [
    "sunrise":     Mesh(base: "#6a2cff", blobs: [Blob(0.05, 0.05, 0.85, "#ff2d4d"), Blob(0.35, 0.0, 0.6, "#ff9a3d", 0.9), Blob(0.95, 1.0, 0.7, "#5b2bff")]),
    "bubblegum":   Mesh(base: "#2a0a6b", blobs: [Blob(0.1, 0.1, 0.9, "#ff4fd8"), Blob(0.55, 0.45, 0.6, "#b5179e", 0.8), Blob(1.0, 1.0, 0.6, "#1b0a4a")]),
    "pastel":      Mesh(base: "#c6a8ea", blobs: [Blob(0.05, 0.05, 0.85, "#ffd0e0"), Blob(0.95, 0.95, 0.75, "#9a7be0"), Blob(0.7, 0.1, 0.4, "#f6e0ff", 0.7)]),
    "cosmic":      Mesh(base: "#06060b", blobs: [Blob(0.85, 1.05, 0.75, "#7b3fe4", 0.95), Blob(0.45, 1.12, 0.55, "#ff6ec7", 0.75), Blob(0.98, 0.98, 0.3, "#ffffff", 0.55)]),
    "cosmic-warm": Mesh(base: "#0b0b0d", blobs: [Blob(0.5, 1.12, 0.85, "#ff9d7a", 0.85), Blob(0.2, 1.05, 0.5, "#ffd6c9", 0.55), Blob(0.85, 1.05, 0.45, "#c24b8a", 0.6)]),
    "mystic":      Mesh(base: "#e8e6f2", blobs: [Blob(0.5, 1.2, 1.0, "#a39cf5", 0.55), Blob(0.5, 1.18, 0.7, "#5b4df0", 0.85), Blob(0.5, 1.15, 0.38, "#2a22d8", 0.95)]),
    "midnight":    Mesh(base: "#05070f", blobs: [Blob(0.15, 0.2, 0.7, "#1b4fd8", 0.7), Blob(0.9, 0.9, 0.7, "#0fb5a6", 0.55), Blob(0.6, 0.5, 0.5, "#4b2bb8", 0.4)]),
    "goldglow":    Mesh(base: "#0a0a0a", blobs: [Blob(0.88, 0.95, 0.75, "#c9a24b", 0.85), Blob(0.1, 0.0, 0.55, "#6b5318", 0.55), Blob(0.95, 1.0, 0.3, "#ffe9a8", 0.5)]),
    "glass-orange": Mesh(base: "#ff8a1f", blobs: [Blob(0.88, 0.1, 0.5, "#2bd4c4", 0.9), Blob(0.1, 0.9, 0.6, "#ffd36b", 0.85), Blob(0.5, 0.5, 0.5, "#ff5a1f", 0.6)], ribbed: true),
    "glass-blue":   Mesh(base: "#1b2a8f", blobs: [Blob(0.2, 0.2, 0.7, "#9db4ff", 0.9), Blob(0.9, 0.9, 0.7, "#05061f", 0.9), Blob(0.7, 0.1, 0.4, "#6d5bff", 0.7)], ribbed: true),
    "glass-fire":   Mesh(base: "#120a05", blobs: [Blob(0.2, 0.3, 0.6, "#ff9a1f", 0.95), Blob(0.8, 0.7, 0.6, "#ff3b1f", 0.9), Blob(0.5, 0.1, 0.4, "#ffe066", 0.8)], ribbed: true),
]

func drawMesh(_ ctx: CGContext, _ m: Mesh, W: Int, H: Int) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let Wf = CGFloat(W), Hf = CGFloat(H)
    ctx.setFillColor(color(m.base))
    ctx.fill(CGRect(x: 0, y: 0, width: Wf, height: Hf))
    for b in m.blobs {
        let c = CGPoint(x: b.x * Wf, y: (1 - b.y) * Hf)
        let g = CGGradient(colorsSpace: cs,
                           colors: [color(b.hex, alpha: b.a), color(b.hex, alpha: 0)] as CFArray,
                           locations: nil)!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: b.r * Wf, options: [])
    }
    guard m.ribbed else { return }
    // Fluted-glass effect: each vertical flute is lighter on the left, darker on the right
    let sw = Wf / 110
    let flute = CGGradient(colorsSpace: cs,
                           colors: [color("#ffffff", alpha: 0.18), color("#ffffff", alpha: 0.0), color("#000000", alpha: 0.22)] as CFArray,
                           locations: [0, 0.5, 1])!
    var x: CGFloat = 0
    while x < Wf {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: 0, width: sw, height: Hf))
        ctx.drawLinearGradient(flute, start: CGPoint(x: x, y: 0), end: CGPoint(x: x + sw, y: 0), options: [])
        ctx.restoreGState()
        x += sw
    }
}

func fillImage(_ ctx: CGContext, _ img: CGImage, W: Int, H: Int) {
    let s = max(CGFloat(W) / CGFloat(img.width), CGFloat(H) / CGFloat(img.height))
    let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
    ctx.draw(img, in: CGRect(x: (CGFloat(W) - dw) / 2, y: (CGFloat(H) - dh) / 2, width: dw, height: dh))
}

let imageExts = ["heic", "jpg", "jpeg", "png"]
let systemWallpaperDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")

func resolveImageBackground(_ spec: String) -> CGImage? {
    let lower = spec.lowercased()
    let fm = FileManager.default

    if lower == "wallpaper" || lower == "desktop" {
        guard let screen = NSScreen.main,
              var url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = files.first(where: { imageExts.contains($0.pathExtension.lowercased()) }) else { return nil }
            url = first
        }
        return loadImage(url.path)
    }
    if lower.hasPrefix("macos:") {
        let name = String(lower.dropFirst(6))
        let files = (try? fm.contentsOfDirectory(at: systemWallpaperDir, includingPropertiesForKeys: nil)) ?? []
        guard let f = files.first(where: { $0.lastPathComponent.lowercased().contains(name)
                                           && imageExts.contains($0.pathExtension.lowercased()) }) else { return nil }
        return loadImage(f.path)
    }
    let p = (spec as NSString).expandingTildeInPath
    return fm.fileExists(atPath: p) ? loadImage(p) : nil
}

func drawBackground(_ ctx: CGContext, spec: String, W: Int, H: Int) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let fullRect = CGRect(x: 0, y: 0, width: W, height: H)

    // Mesh / ribbed-glass presets
    if let m = meshes[spec.lowercased()] { drawMesh(ctx, m, W: W, H: H); return }

    // Image background: file path, "wallpaper", or "macos:<name>" (aspect-fill)
    if let img = resolveImageBackground(spec) { fillImage(ctx, img, W: W, H: H); return }
    let lower = spec.lowercased()
    if lower == "wallpaper" || lower == "desktop" || lower.hasPrefix("macos:") {
        FileHandle.standardError.write("Couldn't load \"\(spec)\" (dynamic/video wallpapers often aren't a plain image file). Falling back to gold. Try --list-bgs or pass an image path.\n".data(using: .utf8)!)
        drawBackground(ctx, spec: "gold", W: W, H: H)
        return
    }

    let stops: [String]
    if let p = presets[spec.lowercased()] { stops = p }
    else { stops = spec.split(separator: ",").map(String.init) }

    if stops.count <= 1 {
        ctx.setFillColor(color(stops.first ?? "#222"))
        ctx.fill(fullRect)
        return
    }

    let cols = stops.map { color($0) } as CFArray
    guard let grad = CGGradient(colorsSpace: cs, colors: cols, locations: nil) else { return }
    // Diagonal, top-left -> bottom-right (CG origin is bottom-left)
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(H)),
                           end: CGPoint(x: CGFloat(W), y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Soft highlight glow, top-left, for depth
    let glow = CGGradient(colorsSpace: cs,
                          colors: [color("#ffffff", alpha: 0.14), color("#ffffff", alpha: 0)] as CFArray,
                          locations: nil)!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: CGFloat(W) * 0.25, y: CGFloat(H) * 0.85), startRadius: 0,
                           endCenter: CGPoint(x: CGFloat(W) * 0.25, y: CGFloat(H) * 0.85), endRadius: CGFloat(W) * 0.6,
                           options: [])
}

// True if the image is (almost) fully transparent, which is what screencapture returns
// when the terminal lacks Screen Recording permission or the window isn't renderable.
func isBlank(_ img: CGImage) -> Bool {
    let n = 64
    var buf = [UInt8](repeating: 0, count: n * n * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    buf.withUnsafeMutableBytes { raw in
        guard let c = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                bytesPerRow: n * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        c.interpolationQuality = .medium
        c.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
    }
    for i in stride(from: 3, to: buf.count, by: 4) where buf[i] > 8 { return false }
    return true
}

func warn(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

// MARK: - Main

var o = parseArgs()

if o.list {
    for w in onScreenWindows() {
        print("\(w.owner)  |  \(w.title.isEmpty ? "(no title)" : w.title)  |  \(Int(w.rect.width))x\(Int(w.rect.height))")
    }
    exit(0)
}
if o.listBgs {
    print("Linear:       " + presets.keys.sorted().joined(separator: ", "))
    print("Mesh / glass: " + meshes.keys.sorted().joined(separator: ", "))
    print("Custom:       \"#hex,#hex,#hex\" | wallpaper | macos:<name> | /path/to/image")
    let files = (try? FileManager.default.contentsOfDirectory(at: systemWallpaperDir, includingPropertiesForKeys: nil)) ?? []
    let names = files.filter { imageExts.contains($0.pathExtension.lowercased()) }
        .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    print("macOS wallpapers (use macos:<name>): " + (names.isEmpty ? "(none found)" : names.joined(separator: ", ")))
    exit(0)
}
guard !o.app.isEmpty else { die("Give an app name, e.g. ./appshot.swift Arbor   (use --list to see running windows)") }

if !CGPreflightScreenCaptureAccess() {
    _ = CGRequestScreenCaptureAccess()
    warn("⚠️  Screen Recording permission looks missing for the app running this script (Terminal, iTerm, Ghostty, VS Code…).\n    Enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then fully QUIT and reopen that app.")
}

if o.activate {
    run("/usr/bin/osascript", ["-e", "tell application \"\(o.app)\" to activate"])
    Thread.sleep(forTimeInterval: o.delay)
}

guard let win = findWindow(app: o.app, title: o.title) else {
    die("No on-screen window found for \"\(o.app)\". Is it running and not minimized? Try --list.")
}

print("Capturing: \(win.owner) | \"\(win.title.isEmpty ? "(no title)" : win.title)\" | \(Int(win.rect.width))x\(Int(win.rect.height)) pt | window id \(win.id)")

let outPath = (o.out ?? "\(o.app)-screenshot.png")
let rawPath = o.clean ? outPath : NSTemporaryDirectory() + "appshot-\(win.id).png"

// -o: no system shadow, -x: no sound, -l: capture that window ID only
run("/usr/sbin/screencapture", ["-o", "-x", "-l", String(win.id), rawPath])

guard FileManager.default.fileExists(atPath: rawPath) else {
    die("Capture failed. Grant your terminal Screen Recording permission in System Settings > Privacy & Security.")
}
guard let shot = loadImage(rawPath) else { die("Couldn't read captured image.") }
if isBlank(shot) {
    die("""
    The captured window image is fully transparent, so nothing would show up. Likely causes:
      1. Screen Recording permission is missing for your terminal app. Enable it, then fully quit and reopen the terminal.
      2. The wrong window was matched (see the 'Capturing:' line above). Use --list, then --title "<text>" to pick one.
      3. The window is on another Space or minimized. Bring it to the current desktop.
    Raw capture kept at: \(rawPath)
    """)
}
if o.clean { print("Saved \(outPath)"); exit(0) }
try? FileManager.default.removeItem(atPath: rawPath)

let W = o.w, H = o.h
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    die("Couldn't create canvas.")
}
ctx.interpolationQuality = .high

drawBackground(ctx, spec: o.bg, W: W, H: H)

// Fit window into padded area, centered
let availW = CGFloat(W) * (1 - 2 * o.pad), availH = CGFloat(H) * (1 - 2 * o.pad)
var scale = min(availW / CGFloat(shot.width), availH / CGFloat(shot.height))
if !o.upscale { scale = min(scale, 1.0) }
let dw = CGFloat(shot.width) * scale, dh = CGFloat(shot.height) * scale
let dest = CGRect(x: (CGFloat(W) - dw) / 2, y: (CGFloat(H) - dh) / 2, width: dw, height: dh)

// Two shadows: wide soft ambient + tight contact shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(H) * 0.025), blur: CGFloat(H) * 0.06,
              color: color("#000000", alpha: 0.45))
ctx.draw(shot, in: dest)
ctx.restoreGState()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(H) * 0.004), blur: CGFloat(H) * 0.012,
              color: color("#000000", alpha: 0.35))
ctx.draw(shot, in: dest)
ctx.restoreGState()

guard let final = ctx.makeImage(),
      let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil) else {
    die("Couldn't write output.")
}
CGImageDestinationAddImage(dst, final, nil)
guard CGImageDestinationFinalize(dst) else { die("Couldn't finalize PNG.") }
print("Saved \(outPath)  (\(W)x\(H), window scaled \(String(format: "%.0f", scale * 100))%)")
