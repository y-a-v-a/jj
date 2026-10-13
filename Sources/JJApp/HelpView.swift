import SwiftUI

/// Every gesture and shortcut on one page.
struct HelpView: View {
    private struct Item: Identifiable {
        var id: String { action }
        let keys: String
        let action: String
    }

    private struct Group: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let items: [Item]
    }

    private let groups: [Group] = [
        Group(title: "Moving around", symbol: "hand.draw", items: [
            Item(keys: "⌘ scroll · pinch", action: "Zoom where the pointer is"),
            Item(keys: "−  =  +", action: "Zoom out, show the whole map, zoom in (⌘−, ⌘0, ⌘+)"),
            Item(keys: "Drag · scroll", action: "Pan the map"),
            Item(keys: "Double-click", action: "Zoom in there"),
            Item(keys: "Click", action: "Outline the piece under the pointer"),
            Item(keys: "⌥ click", action: "Centre the layout on that place"),
        ]),
        Group(title: "Folding", symbol: "globe.europe.africa", items: [
            Item(keys: "⌘G", action: "Fold the map into the globe, or unfold it"),
            Item(keys: "Slider", action: "Anything between the globe and the map"),
            Item(keys: "Drag", action: "Spin the folded globe"),
            Item(keys: "⌥⌘G", action: "Close the gaps: van Wijk's figure 13"),
        ]),
        Group(title: "Layouts and worlds", symbol: "square.grid.2x2", items: [
            Item(keys: "⌘]  ⌘[", action: "Next and previous layout"),
            Item(keys: "⌘T", action: "Tour every layout of every world, folding between them"),
            Item(keys: "⌘1 … ⌘4", action: "The Earth, the Moon, Mars, Venus"),
            Item(keys: "⌘F", action: "Find a place: where did it go?"),
        ]),
        Group(title: "Time", symbol: "clock", items: [
            Item(keys: "Scrubber", action: "A day either way: the night and the clocks move"),
            Item(keys: "▶▶", action: "Time-lapse, an hour a second"),
            Item(keys: "⌥⌘0", action: "Back to now"),
        ]),
        Group(title: "Layers", symbol: "square.3.layers.3d", items: [
            Item(keys: "⌥⌘K  ⌥⌘F", action: "Cut edges, faces"),
            Item(keys: "⌥⌘L  ⌥⌘N", action: "Graticule, day and night"),
            Item(keys: "⌥⌘T  ⌥⌘B", action: "Tissot's indicatrices, labels"),
        ]),
        Group(title: "Keeping it", symbol: "square.and.arrow.up", items: [
            Item(keys: "Export", action: "PNG up to 8K, an unfolding GIF or 4K film, the clipboard"),
            Item(keys: "⌘P", action: "Print a paper globe to cut out, fold and glue"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("JJ at your fingertips").font(.title2.weight(.semibold))
                    Text("Every layout cuts the same globe open a different way; these are the ways to look at them.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(group.title, systemImage: group.symbol).font(.headline)
                            ForEach(group.items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(item.keys)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 130, alignment: .leading)
                                    Text(item.action).font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 760, height: 560)
    }
}
