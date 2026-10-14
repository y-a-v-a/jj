import MyriaData
import SwiftUI

/// The licences JJ ships under: its own, the code it ports and its data.
enum Licences {
    static let jj = """
        MIT License

        Copyright (c) 2026 Vincent Bruijn

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """

    static let earcut = """
        ISC License

        Copyright (c) 2026, Mapbox

        Permission to use, copy, modify, and/or distribute this software for any purpose \
        with or without fee is hereby granted, provided that the above copyright notice \
        and this permission notice appear in all copies.

        THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH \
        REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND \
        FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, \
        INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS \
        OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER \
        TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF \
        THIS SOFTWARE.
        """

    /// Every world's datasets, each source once, with its licence.
    static var data: [String] {
        CelestialBody.all.flatMap { $0.datasets.map(\.attribution) }.reduce(into: [String]()) { list, a in
            if !list.contains(a) { list.append(a) }
        }
    }
}

/// The Licences window, opened from About JJ.
struct LicencesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("JJ", Licences.jj)
                Divider()
                Text("Earcut").font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    Text("JJ triangulates polygons with a Swift port of Mapbox's earcut.")
                    Link("github.com/mapbox/earcut", destination: URL(string: "https://github.com/mapbox/earcut")!)
                }
                .font(.callout)
                legal(Licences.earcut)
                Divider()
                Text("Data").font(.headline)
                Text("The data keep their own licences. Each world's SOURCES.md, among the app's resources, gives the full sources and how to cite them.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Licences.data, id: \.self) { Text("· \($0)") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 600, height: 560)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            legal(text)
        }
    }

    private func legal(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
