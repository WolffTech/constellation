// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Reads the workspace feed Azure Virtual Desktop clients subscribe to. Feed
/// discovery lists one feed per tenant the account belongs to, and each feed
/// lists the account's resources with a link to their connection file. The
/// feed is the Remote Desktop web feed (MS-TSWP); discovery is not documented.
public enum AVDFeed {
    public static let discoveryContentType = "application/x-msts-radc-discovery+xml,text/xml"
    public static let feedContentType = "application/x-msts-radc+xml;radc_schema_version=2.0,text/xml"

    public struct TenantFeed: Hashable, Sendable {
        public var url: URL
        public var tenantName: String?
    }

    /// A full desktop the account may connect to.
    public struct Desktop: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var tenantName: String?
        /// Serves the desktop's `.rdp` file to the signed-in account.
        public var connectionFileURL: URL
    }

    public static func tenantFeeds(fromDiscovery data: Data, in cloud: AVDCloud) throws -> [TenantFeed] {
        try elements(in: data).compactMap { element in
            guard element.name == "TenantFeedURL",
                  let url = element.attributes["FeedURL"].flatMap({ URL(string: $0, relativeTo: cloud.feedDiscoveryURL) })
            else { return nil }
            return TenantFeed(url: url.absoluteURL, tenantName: element.attributes["TenantDisplayName"])
        }
    }

    /// The desktops in a tenant's feed. RemoteApps are left out.
    public static func desktops(fromFeed data: Data, of feed: TenantFeed) throws -> [Desktop] {
        var desktops: [Desktop] = []
        var resource: [String: String]?
        for element in try elements(in: data) {
            switch element.name {
            case "Resource":
                resource = element.attributes
            case "ResourceFile":
                // A resource may list several hosts; the first file is enough.
                guard let attributes = resource, attributes["Type"]?.lowercased() == "desktop",
                      let id = attributes["ID"],
                      let url = element.attributes["URL"].flatMap({ URL(string: $0, relativeTo: feed.url) })
                else { continue }
                desktops.append(Desktop(
                    id: id, title: attributes["Title"] ?? id, tenantName: feed.tenantName,
                    connectionFileURL: url.absoluteURL))
                resource = nil
            default:
                break
            }
        }
        return desktops
    }

    private struct Element {
        var name: String
        var attributes: [String: String]
    }

    /// Every element in document order, with any namespace prefix dropped.
    private static func elements(in data: Data) throws -> [Element] {
        let collector = ElementCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw AVDFeedError.unreadable }
        return collector.elements
    }

    private final class ElementCollector: NSObject, XMLParserDelegate {
        var elements: [Element] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            elements.append(Element(name: name, attributes: attributes))
        }
    }
}

public enum AVDFeedError: Error, Hashable, Sendable, LocalizedError {
    case unreadable

    public var errorDescription: String? {
        "Azure Virtual Desktop sent a workspace feed that could not be read."
    }
}
