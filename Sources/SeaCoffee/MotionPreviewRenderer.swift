import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import IslandCore

@MainActor
enum MotionPreviewRenderer {
    static func render(to path: String) {
        let count = 135
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString, count, nil) else { exit(1) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<count {
            autoreleasepool {
                let elapsed = Double(index) / 30
                let renderer = ImageRenderer(content: MotionPreviewFrame(elapsed: elapsed))
                renderer.scale = 2
                guard let image = renderer.cgImage else { return }
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
                if index == 88 {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"))
                }
            }
        }
        guard CGImageDestinationFinalize(destination) else { exit(1) }
        print("Rendered motion preview: \(count) frames")
    }
}

private struct MotionPreviewFrame: View {
    let elapsed: Double
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sea Coffee").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("动效预览 · 演示数据").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 26).frame(height: 50)
            CompletionSurface(motion: CompletionMotion(elapsed: max(0, elapsed - 0.55)),
                initialWidth: 291, initialHeight: 32, targetWidth: 291, targetHeight: 32,
                cameraHeight: 32, badgeWidth: 179, hasNotch: true) {
                    HStack(spacing: 0) {
                        HStack(spacing: 3) {
                            ActivityCore(state: .running, reducedMotion: false, timeOverride: elapsed)
                                .frame(width: 23, height: 23)
                            Text(elapsed < 0.55 ? "3" : "2").font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(ActivityAppearance.running.tint)
                        }.frame(width: 56)
                        Color.clear.frame(width: 179)
                        HStack(spacing: 4) {
                            QuotaRing(fraction: 0.68, lineWidth: 2, reducedMotion: true).frame(width: 15, height: 15)
                            Text("68%").font(.system(size: 10, design: .rounded)).foregroundStyle(.white)
                        }.frame(width: 56)
                    }.frame(height: 32)
                }
                .frame(height: 158, alignment: .top).clipped()
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                        bottomTrailingRadius: 10, topTrailingRadius: 0)
                        .fill(.black).frame(width: 179, height: 32)
                }
            HStack(spacing: 32) {
                sample(.running, label: "运行 · 3")
                sample(.failed, label: "报错")
                sample(.completed, label: "完成")
            }.frame(height: 50)
        }
        .frame(width: 520, height: 280)
        .background(Color(red: 0.075, green: 0.085, blue: 0.10))
        .environment(\.colorScheme, .dark)
    }
    private func sample(_ state: ActivityAppearance, label: String) -> some View {
        HStack(spacing: 6) {
            ActivityCore(state: state, reducedMotion: false, timeOverride: elapsed).frame(width: 20, height: 20)
            Text(label).font(.system(size: 11)).foregroundStyle(state.tint)
        }
    }
}
