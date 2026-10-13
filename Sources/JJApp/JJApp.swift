import AppKit
import MyriaCore
import MyriaLayouts
import MyriaRender
import SwiftUI

@main
struct JJApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Launched with `swift run` there is no bundle: still behave as a
        // regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("JJ", id: "map") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1600, height: 960)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About JJ") { openWindow(id: "about") }
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { zoom(1.6) }.keyboardShortcut("+", modifiers: .command)
                Button("Zoom In") { zoom(1.6) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { zoom(1 / 1.6) }.keyboardShortcut("-", modifiers: .command)
                Button("Show the Whole Map") { model.camera = MapCamera() }.keyboardShortcut("0", modifiers: .command)
                Divider()
                Button(model.unfold >= 1 ? "Fold into a Globe" : "Unfold the Map") { model.toggleFold() }
                    .keyboardShortcut("g", modifiers: .command)
                Divider()
                Toggle("Cut Edges", isOn: model.layerBinding(.cuts)).keyboardShortcut("k", modifiers: [.command, .option])
                Toggle("Faces", isOn: model.layerBinding(.mesh)).keyboardShortcut("f", modifiers: [.command, .option])
                Toggle("Graticule", isOn: model.layerBinding(.graticule)).keyboardShortcut("l", modifiers: [.command, .option])
                Toggle("Day and Night", isOn: model.layerBinding(.night)).keyboardShortcut("n", modifiers: [.command, .option])
                Toggle("Tissot's Indicatrices", isOn: model.layerBinding(.tissot)).keyboardShortcut("t", modifiers: [.command, .option])
                Toggle("Labels", isOn: model.layerBinding(.labels)).keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
            }
            CommandMenu("Layout") {
                Button("Next Layout") { model.selectNext(1) }.keyboardShortcut("]", modifiers: .command)
                Button("Previous Layout") { model.selectNext(-1) }.keyboardShortcut("[", modifiers: .command)
                Button(model.isTouring ? "Stop the Tour" : "Start the Tour") { model.toggleTour() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                ForEach(LayoutCategory.allCases, id: \.self) { category in
                    Menu(category.title) {
                        ForEach(model.catalog.filter { $0.descriptor.category == category }, id: \.descriptor.id) { layout in
                            Button(layout.descriptor.title) { model.layoutID = layout.descriptor.id }
                        }
                    }
                }
                Divider()
                Button("Back to Now") { model.timeOffset = 0 }.keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
        Window("About JJ", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView(model: model)
        }
    }

    @MainActor private func zoom(_ factor: Double) {
        let size = NSApp.keyWindow?.contentView?.bounds.size ?? CGSize(width: 1200, height: 800)
        let mapSize = CGSize(width: max(size.width - 600, 400), height: size.height)
        guard var v = MapGeometry.mapViewport(model, size: mapSize) else { return }
        v.zoom(by: factor, around: Vec2(mapSize.width / 2, mapSize.height / 2))
        model.camera = MapCamera(zoom: v.zoom, center: v.center)
    }
}
