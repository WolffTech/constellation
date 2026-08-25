import SwiftUI

/// Third-party notices, read from `Licenses/manifest.json` and the license
/// texts beside it in the bundle. Help › Acknowledgements opens the window.
struct AcknowledgementsView: View {
    @State private var notices = Notice.loadBundled()
    @State private var selection: Notice.ID?

    var body: some View {
        NavigationSplitView {
            List(notices, selection: $selection) { notice in
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.name)
                    Text("\(notice.version) · \(notice.license)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if let notice = notices.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(notice.name).font(.title2)
                        Text(notice.summary)
                        Link(notice.url.absoluteString, destination: notice.url)
                        Divider()
                        Text(notice.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            } else {
                ContentUnavailableView("Acknowledgements", systemImage: "doc.text",
                                       description: Text("Constellation is built with the open-source software listed here."))
            }
        }
        .navigationTitle("Acknowledgements")
        .onAppear { if selection == nil { selection = notices.first?.id } }
    }
}

struct Notice: Identifiable, Decodable, Hashable {
    var name: String
    var version: String
    var license: String
    var url: URL
    /// One or two sentences: what the component does for Constellation.
    var summary: String
    /// File name of the license text inside `Licenses/`.
    var file: String
    var text = ""

    var id: String { name }

    private enum CodingKeys: String, CodingKey { case name, version, license, url, summary, file }

    static func loadBundled(bundle: Bundle = .main) -> [Notice] {
        guard let manifest = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "Licenses"),
              let data = try? Data(contentsOf: manifest),
              var notices = try? JSONDecoder().decode([Notice].self, from: data) else {
            return []
        }
        for index in notices.indices {
            let file = manifest.deletingLastPathComponent().appendingPathComponent(notices[index].file)
            notices[index].text = (try? String(contentsOf: file, encoding: .utf8)) ?? "License text missing from the bundle."
        }
        return notices
    }
}
