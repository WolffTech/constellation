// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import ConstellationCore

struct AVDFeedTests {
    @Test func listsOneFeedPerTenant() throws {
        let discovery = """
            <?xml version="1.0" encoding="utf-8"?>
            <TenantFeedURLs xmlns="http://schemas.microsoft.com/ts/2019/01/tswf">
              <TenantFeedURL FeedURL="https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/feed?t=1" TenantId="7706" TenantDisplayName="Contoso" />
              <TenantFeedURL FeedURL="https://rdweb-g-eu-r1.wvd.microsoft.com/api/arm/hubs/feed?t=2" TenantId="8807" />
            </TenantFeedURLs>
            """
        let feeds = try AVDFeed.tenantFeeds(fromDiscovery: Data(discovery.utf8), in: .commercial)
        #expect(feeds == [
            AVDFeed.TenantFeed(url: URL(string: "https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/feed?t=1")!, tenantName: "Contoso"),
            AVDFeed.TenantFeed(url: URL(string: "https://rdweb-g-eu-r1.wvd.microsoft.com/api/arm/hubs/feed?t=2")!, tenantName: nil),
        ])
    }

    @Test func listsDesktopsAndLeavesOutRemoteApps() throws {
        let feed = AVDFeed.TenantFeed(url: URL(string: "https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/feed")!, tenantName: "Contoso")
        let xml = """
            <ResourceCollection PubDate="2026-09-20T00:00:00Z" SchemaVersion="2.0" xmlns="http://schemas.microsoft.com/ts/2007/05/tswf">
              <Publisher Name="Engineering" ID="ws1">
                <Resources>
                  <Resource ID="desk1" Alias="desk1" Title="SessionDesktop" Type="Desktop">
                    <Icons><Icon32 Dimensions="32x32" FileURL="https://example.com/i.png" /></Icons>
                    <HostingTerminalServers>
                      <HostingTerminalServer>
                        <ResourceFile FileExtension=".rdp" URL="https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/resource/desk1.rdp" />
                        <TerminalServerRef Ref="ts1" />
                      </HostingTerminalServer>
                      <HostingTerminalServer>
                        <ResourceFile FileExtension=".rdp" URL="https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/resource/desk1-b.rdp" />
                      </HostingTerminalServer>
                    </HostingTerminalServers>
                  </Resource>
                  <Resource ID="app1" Title="Excel" Type="RemoteApp">
                    <HostingTerminalServers><HostingTerminalServer>
                      <ResourceFile FileExtension=".rdp" URL="https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/resource/app1.rdp" />
                    </HostingTerminalServer></HostingTerminalServers>
                  </Resource>
                  <Resource ID="desk2" Title="Cloud PC" Type="Desktop">
                    <HostingTerminalServers><HostingTerminalServer>
                      <ResourceFile FileExtension=".rdp" URL="/api/arm/hubs/resource/desk2.rdp" />
                    </HostingTerminalServer></HostingTerminalServers>
                  </Resource>
                </Resources>
              </Publisher>
            </ResourceCollection>
            """
        let desktops = try AVDFeed.desktops(fromFeed: Data(xml.utf8), of: feed)
        #expect(desktops.map(\.title) == ["SessionDesktop", "Cloud PC"])
        #expect(desktops.map(\.tenantName) == ["Contoso", "Contoso"])
        #expect(desktops.map(\.connectionFileURL.absoluteString) == [
            "https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/resource/desk1.rdp",
            "https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/resource/desk2.rdp",
        ])
    }

    @Test func rejectsAFeedThatIsNotXML() {
        #expect(throws: AVDFeedError.unreadable) {
            try AVDFeed.tenantFeeds(fromDiscovery: Data("INCOMPATIBLE_CLIENT_VERSION".utf8), in: .commercial)
        }
    }
}
