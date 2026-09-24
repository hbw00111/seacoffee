import AppKit
import SwiftUI
import IslandCore

@main
enum SeaCoffeeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--render-motion"), CommandLine.arguments.count > index + 1 {
            MotionPreviewRenderer.render(to: CommandLine.arguments[index + 1]); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            PreviewRenderer.render(to: CommandLine.arguments[index + 1]); return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = IslandModel()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var mouseTimer: Timer?
    private var observer: NSObjectProtocol?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EditingMenu.install()
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Sea Coffee"
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false; panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        model.openSettings = { [weak self] in self?.showSettings() }
        model.geometryChanged = { [weak self] in self?.placePanel() }
        placePanel(); panel.orderFrontRegardless()
        createMenu()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placePanel() }
        }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMouse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.model.pinned = false; self?.model.setExpanded(false) }
            }
            return event
        }
        model.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            model.setExpanded(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.model.scheduleCollapse() }
        }
        if CommandLine.arguments.contains("--demo") { model.preview() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop(); mouseTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.setExpanded(true); panel.orderFrontRegardless(); return true
    }
    private func placePanel() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let inset = screen.safeAreaInsets.top
        model.hasNotch = inset > 0
        model.notchHeight = inset
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, inset > 0 {
            model.notchWidth = max(120, right.minX - left.maxX)
        } else { model.notchWidth = 120 }
        let top = screen.frame.maxY - (inset > 0 ? 0 : 10)
        panel.setFrame(NSRect(x: screen.frame.midX - 260, y: top - 370, width: 520, height: 370), display: true)
    }
    private func updateMouse() {
        guard panel.isVisible else { return }
        let frame = NSRect(x: panel.frame.midX - model.islandWidth / 2,
                           y: panel.frame.maxY - model.surfaceTopInset - model.islandHeight,
                           width: model.islandWidth, height: model.islandHeight)
        let inside = frame.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        model.hover(inside)
    }
    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sea Coffee")
        let menu = NSMenu()
        add("展开 Sea Coffee", #selector(expand), to: menu)
        add("固定展开", #selector(togglePin(_:)), to: menu)
        add("预览动画", #selector(preview), to: menu)
        add("刷新额度", #selector(refresh), to: menu)
        menu.addItem(.separator())
        add("设置…", #selector(settings), to: menu, key: ",")
        menu.addItem(.separator())
        add("退出 Sea Coffee", #selector(quit), to: menu, key: "q")
        statusItem.menu = menu
    }
    private func add(_ title: String, _ selector: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    @objc private func expand() { model.setExpanded(true); model.scheduleCollapse(after: 1.2) }
    @objc private func togglePin(_ sender: NSMenuItem) {
        model.togglePin(); sender.state = model.pinned ? .on : .off
        if model.pinned { model.setExpanded(true) }
    }
    @objc private func preview() { model.preview() }
    @objc private func refresh() { model.refresh() }
    @objc private func settings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Sea Coffee · 设置"; window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            // Clear window so the SwiftUI backdrop can blur the desktop behind it.
            window.isOpaque = false; window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: SettingsView(model: model))
            // The SwiftUI root already covers the titlebar; don't let the safe area grow the window.
            host.sizingOptions = []
            window.contentView = host
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum PreviewRenderer {
    static func render(to path: String) {
        let running = IslandModel(); running.demo = true; running.demoRunning = true
        running.expanded = true; running.reducedMotion = true; running.notchWidth = 120; running.notchHeight = 0
        let done = IslandModel(); done.demo = true; done.demoRunning = false
        done.completion = CompletionPresentation(isDemo: true)
        done.expanded = true; done.reducedMotion = true; done.notchWidth = 120; done.notchHeight = 0
        let compact = IslandModel(); compact.demo = true; compact.demoRunning = true
        compact.reducedMotion = true; compact.notchWidth = 120; compact.notchHeight = 0
        let view = PreviewCanvas(running: running, done: done, compact: compact)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { fputs("Preview render failed\n", stderr); exit(1) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)); print("Rendered \(path)") }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
}

struct PreviewCanvas: View {
    let running: IslandModel
    let done: IslandModel
    let compact: IslandModel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.19, blue: 0.22), Color(red: 0.07, green: 0.10, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Palette.mint.opacity(0.08)).frame(width: 600).blur(radius: 110).offset(x: -350, y: 50)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle").foregroundStyle(Palette.mint).font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sea Coffee").font(.system(size: 24, weight: .medium))
                        Text("余额与任务状态，一眼看清。")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Text("MACOS · PREVIEW 01").font(.system(size: 9, design: .monospaced)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
                }.padding(.horizontal, 60).padding(.top, 40)
                Text("收起").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.top, 38)
                IslandView(model: compact).frame(height: 48, alignment: .top).clipped().padding(.top, 14)
                HStack(spacing: 0) {
                    VStack(spacing: 14) {
                        Text("运行中").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        IslandView(model: running).frame(width: 440, height: 320, alignment: .top)
                    }
                    VStack(spacing: 14) {
                        Text("本轮完成").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        IslandView(model: done).frame(width: 440, height: 320, alignment: .top)
                    }
                }.padding(.top, 24)
                Spacer(minLength: 0)
                Text("图中为演示数据 · 支持 Sub2API、Codex 官方与 Cline Pass")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3)).padding(.bottom, 30)
            }
        }.frame(width: 960, height: 680).foregroundStyle(.white).preferredColorScheme(.dark)
        .environment(\.glassSnapshot, true)
    }
}
