import AppKit
import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows macOS. Every palette has a light and a dark variant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Palette") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(Palette.all) { palette in
                        PaletteCard(palette: palette, style: palette.style(dark: colorScheme == .dark),
                                    isSelected: model.paletteID == palette.id) { model.paletteID = palette.id }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Drawing") {
                Toggle("Seal hairline slits", isOn: $model.sealSlits)
                    .help("Close gaps narrower than a pixel. Off shows every interrupt, as in van Wijk's figures.")
                VStack(alignment: .leading) {
                    Text("Line weight: \(model.lineWeight.formatted(.number.precision(.fractionLength(1))))×")
                    Slider(value: $model.lineWeight, in: 0.5...3)
                }
                Picker("Graticule", selection: $model.graticuleStep) {
                    ForEach([5.0, 10, 15, 30], id: \.self) { Text("Every \(Int($0))°").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PaletteCard: View {
    let palette: Palette
    let style: PaletteStyle
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color(rgba: style.background)
                    HStack(spacing: 0) {
                        Color(rgba: style.ocean)
                        Color(rgba: style.land)
                    }
                    .frame(height: 22)
                    .clipShape(Capsule())
                    .padding(.horizontal, 16)
                    .offset(y: -10)
                    HStack(spacing: 3) {
                        ForEach(style.categorical.indices, id: \.self) { i in
                            Circle().fill(Color(rgba: style.categorical[i])).frame(width: 12, height: 12)
                        }
                    }
                    .offset(y: 16)
                }
                .frame(height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text(palette.name).font(.headline)
                Text(palette.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(palette.name): \(palette.summary)")
    }
}

/// About JJ: a homage.
struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JJ").font(.largeTitle.weight(.semibold))
                    Text("Myriahedral maps of the Earth, the Moon and Mars").font(.title3).foregroundStyle(.secondary)
                }
            }
            Text("A homage to Jarke J. van Wijk")
                .font(.headline)
            Text("""
                In 2008 Jarke J. van Wijk asked what happens when you take the naive approach to mapping the Earth \
                seriously: stitch together many small, almost undistorted maps. Project the globe onto a polyhedron \
                with a myriad of faces, a myriahedron; label each edge a cut or a fold; unfold. Any spanning tree of \
                the faces is a valid unfolding, and the weights that choose the tree decide what the map is about. \
                The maps have many interrupts, but they are almost conformal and conserve areas, and their gaps show \
                the distortion every other map hides.

                JJ — for Jarke Jan — unfolds the Earth along its coastlines, rivers, plates, timezones, borders, \
                crowds, air routes, winds, rain and the line between day and night; unfolds the Moon and Mars along \
                their craters and the shores of vanished seas; and redraws the figures of the paper on today's GPUs, \
                at sixty frames a second.
                """)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Jarke J. van Wijk, “Unfolding the Earth: Myriahedral Projections”,")
                Text("The Cartographic Journal 45(1), 32–42, 2008. Henry Johns Award 2009.").foregroundStyle(.secondary)
                Link("vanwijk.win.tue.nl/myriahedral", destination: URL(string: "https://vanwijk.win.tue.nl/myriahedral/")!)
            }
            .font(.callout)
            Divider()
            Text(CelestialBody.all.flatMap { $0.datasets.map(\.attribution) }.reduce(into: [String]()) { list, a in
                if !list.contains(a) { list.append(a) }
            }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 520)
    }
}
