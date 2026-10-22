// 把 Canva 导出的图标原图做成 macOS 图标底图：以左上角颜色为底色，找出圆角方块、裁掉四周底色，
// 按 Apple 图标网格（1024 画布、824 圆角方块、圆角半径约 185）放好，角外透明。
// 用法：swift make_icon.swift 输入.png 输出.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("用法：swift make_icon.swift 输入.png 输出.png"); exit(1)
}

// 读像素，找非白像素的外框
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let rgb = CGColorSpaceCreateDeviceRGB()
let readCtx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
readCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
// 和底色差得多的像素算图标本体（底色可能是白，也可能是黑）
let bg = (Int(px[0]), Int(px[1]), Int(px[2]))
func isBackground(_ i: Int) -> Bool {
    abs(Int(px[i]) - bg.0) + abs(Int(px[i + 1]) - bg.1) + abs(Int(px[i + 2]) - bg.2) < 60
}
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        if !isBackground(i) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// 从四个角把连着的底色像素涂黑，免得原图圆角外的白色露进新的圆角里
var stack = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
var seen = [Bool](repeating: false, count: w * h)
while let (x, y) = stack.popLast() {
    guard x >= 0, y >= 0, x < w, y < h, !seen[y * w + x] else { continue }
    seen[y * w + x] = true
    let i = (y * w + x) * 4
    guard isBackground(i) else { continue }
    px[i] = 0; px[i + 1] = 0; px[i + 2] = 0
    stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}
// 往里收 3 像素，去掉抗锯齿的边
let inset = 3
let box = CGRect(x: minX + inset, y: minY + inset, width: maxX - minX - 2 * inset, height: maxY - minY - 2 * inset)
print("圆角方块范围：\(box)")
// px 的行序和 CGImage 一致（第 0 行在上），cropping 用的也是左上原点
let cropped = readCtx.makeImage()!.cropping(to: box)!

let size = 1024, tile = 824.0, radius = 185.0
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: (Double(size) - tile) / 2, y: (Double(size) - tile) / 2, width: tile, height: tile)
out.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
out.clip()
out.setFillColor(CGColor(gray: 0, alpha: 1))
out.fill(rect)
out.interpolationQuality = .high
out.draw(cropped, in: rect)

let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("已生成 \(args[2])")
