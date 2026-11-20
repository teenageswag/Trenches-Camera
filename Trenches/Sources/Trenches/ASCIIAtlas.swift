import CoreText
import Metal

struct ASCIIAtlas {
    let texture: MTLTexture
    private let counts: [Int]
    private static let tileWidth = 32
    private static let tileHeight = 48
    private static let legacyDetailed = " .\u{60}',:;^-~_+<>!iIl1?][}{)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"

    func row(for symbols: ASCIISymbols, legacy: Bool) -> (index: Float, count: Float) {
        let legacyOffset = ASCIISymbols.allCases.count
        var row = symbols.rawValue
        if legacy && symbols == .classic { row = legacyOffset }
        if legacy && symbols == .binary { row = legacyOffset + 1 }
        if legacy && symbols == .blocks { row = legacyOffset + 2 }
        return (Float(row), Float(counts[row]))
    }

    init(device: MTLDevice, queue: MTLCommandQueue) throws {
        let packs = ASCIISymbols.allCases.map { ($0.characters, $0.sortsByDensity) }
            + [(Self.legacyDetailed, false), (" 01", false), (ASCIISymbols.blocks.characters, false)]
        counts = packs.map { $0.0.count }
        let width = counts.max()! * Self.tileWidth
        let height = packs.count * Self.tileHeight
        var buffer = [UInt8](repeating: 0, count: width * height)
        let baseFont = CTFontCreateWithName("Menlo" as CFString, 34, nil)
        var cache: [Character: Glyph] = [:]
        for (row, pack) in packs.enumerated() {
            let legacyBlocks = row == packs.count - 1
            var glyphs: [Glyph] = []
            for character in pack.0 {
                if !legacyBlocks, let cached = cache[character] { glyphs.append(cached) }
                else {
                    let glyph = try Self.rasterize(character, baseFont: baseFont, legacyOrigin: legacyBlocks)
                    if !legacyBlocks { cache[character] = glyph }
                    glyphs.append(glyph)
                }
            }
            if pack.1 {
                glyphs = glyphs.enumerated().sorted { lhs, rhs in
                    lhs.element.ink == rhs.element.ink ? lhs.offset < rhs.offset : lhs.element.ink < rhs.element.ink
                }.map(\.element)
            }
            for (column, glyph) in glyphs.enumerated() {
                for y in 0..<Self.tileHeight {
                    let start = (row * Self.tileHeight + y) * width + column * Self.tileWidth
                    let source = (Self.tileHeight - y - 1) * Self.tileWidth
                    buffer.replaceSubrange(start..<(start + Self.tileWidth), with: glyph.bytes[source..<(source + Self.tileWidth)])
                }
            }
        }
        // All cells share an atlas with aligned mip levels, independent of output resolution and glyph size.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw TrenchesError.message("Не удалось создать атлас ASCII.")
        }
        self.texture = texture
        buffer.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width)
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    private struct Glyph {
        var bytes: [UInt8]
        var ink: Int
    }

    private static func rasterize(_ character: Character, baseFont: CTFont, legacyOrigin: Bool) throws -> Glyph {
        var bytes = [UInt8](repeating: 0, count: Self.tileWidth * Self.tileHeight)
        if character == " " || character == "⠀" { return Glyph(bytes: bytes, ink: 0) }
        let text = String(character)
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let usesBase = CTFontGetGlyphsForCharacters(baseFont, units, &glyphs, units.count)
        let font = usesBase ? baseFont : CTFontCreateForString(baseFont, text as CFString, CFRange(location: 0, length: units.count))
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) else {
            throw TrenchesError.message("Системный шрифт не содержит символ «\(character)».")
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: Self.tileWidth, height: Self.tileHeight,
                                          bitsPerComponent: 8, bytesPerRow: Self.tileWidth, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.textMatrix = .identity
            if legacyOrigin || (usesBase && text.unicodeScalars.allSatisfy(\.isASCII)) {
                context.textPosition = CGPoint(x: 6, y: 12)
            } else {
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                guard !bounds.isEmpty else { return false }
                let scale = min(1, 28 / bounds.width, 42 / bounds.height)
                context.translateBy(x: CGFloat(Self.tileWidth) / 2, y: CGFloat(Self.tileHeight) / 2)
                context.scaleBy(x: scale, y: scale)
                context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
            }
            CTLineDraw(line, context)
            return true
        }
        let ink = bytes.reduce(0) { $0 + Int($1) }
        guard rendered, ink > 0 else { throw TrenchesError.message("Не удалось отрисовать символ «\(character)».") }
        return Glyph(bytes: bytes, ink: ink)
    }
}
