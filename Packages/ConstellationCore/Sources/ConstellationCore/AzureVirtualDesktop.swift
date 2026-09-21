// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// What an Azure Virtual Desktop gateway needs to broker one desktop. The
/// values come from the desktop's connection file and mean nothing to this
/// app; they are kept as given and handed to the gateway at connect time.
public struct AVDResource: Hashable, Sendable, Codable {
    public var endpointPool: String?
    public var geo: String?
    public var armPath: String?
    /// Scopes the Entra ID sign-in page to the desktop's tenant.
    public var tenantID: String?
    public var diagnosticServiceURL: String?
    public var hubDiscoveryURL: String?
    public var activityHint: String?
    public var loadBalanceInfo: String?
    /// The resource's id in its workspace, which the gateway wants for desktops too.
    public var application: String?
    /// The desktop also signs in with Entra ID, so it needs no password.
    public var usesEntraDesktopSignIn: Bool

    public init(
        endpointPool: String? = nil,
        geo: String? = nil,
        armPath: String? = nil,
        tenantID: String? = nil,
        diagnosticServiceURL: String? = nil,
        hubDiscoveryURL: String? = nil,
        activityHint: String? = nil,
        loadBalanceInfo: String? = nil,
        application: String? = nil,
        usesEntraDesktopSignIn: Bool = false
    ) {
        self.endpointPool = endpointPool
        self.geo = geo
        self.armPath = armPath
        self.tenantID = tenantID
        self.diagnosticServiceURL = diagnosticServiceURL
        self.hubDiscoveryURL = hubDiscoveryURL
        self.activityHint = activityHint
        self.loadBalanceInfo = loadBalanceInfo
        self.application = application
        self.usesEntraDesktopSignIn = usesEntraDesktopSignIn
    }
}

public enum AVDConnectionFileError: Error, Hashable, Sendable, LocalizedError {
    case unreadable
    case notAzureVirtualDesktop
    case remoteApp

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The file could not be read as text."
        case .notAzureVirtualDesktop: "This is not an Azure Virtual Desktop connection file. Download one from the Azure Virtual Desktop web client."
        case .remoteApp: "This file opens a RemoteApp. Only full desktops are supported."
        }
    }
}

/// The parts of an Azure Virtual Desktop `.rdp` or `.rdpw` file a connection
/// needs. Display, audio and redirection settings in the file are ignored; the
/// app's own RDP settings apply instead.
public struct AVDConnectionFile: Hashable, Sendable {
    /// The file's `full address`, which becomes the machine's address. The
    /// gateway replaces it with the session host once it has brokered one.
    public var address: String
    /// The desktop's display name, if the file has one.
    public var name: String?
    public var gateway: RDPGateway

    /// Windows writes these files as UTF-16 with a byte order mark; the web
    /// client serves UTF-8.
    public init(data: Data) throws(AVDConnectionFileError) {
        let isUTF16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard let contents = String(data: data, encoding: isUTF16 ? .utf16 : .utf8) else { throw .unreadable }
        try self.init(contents: contents)
    }

    public init(contents: String) throws(AVDConnectionFileError) {
        // Each line is `name:type:value`, and values may contain colons.
        var settings: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let value = parts[2].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { settings[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = value }
        }

        guard settings["resourceprovider"]?.lowercased() == "arm",
              let address = settings["full address"],
              let gatewayHostname = settings["gatewayhostname"]
        else { throw .notAzureVirtualDesktop }
        if settings["remoteapplicationmode"] == "1" { throw .remoteApp }

        var gatewayHost = gatewayHostname
        var gatewayPort = RDPGateway.defaultPort
        if let colon = gatewayHostname.lastIndex(of: ":"), let port = Int(gatewayHostname[gatewayHostname.index(after: colon)...]) {
            gatewayHost = String(gatewayHostname[..<colon])
            gatewayPort = port
        }

        self.address = address
        name = settings["remotedesktopname"]
        gateway = RDPGateway(host: gatewayHost, port: gatewayPort, credentials: .azureVirtualDesktop(AVDResource(
            endpointPool: settings["wvd endpoint pool"],
            geo: settings["geo"],
            armPath: settings["armpath"],
            tenantID: settings["aadtenantid"],
            diagnosticServiceURL: settings["diagnosticserviceurl"],
            hubDiscoveryURL: settings["hubdiscoverygeourl"],
            activityHint: settings["activityhint"],
            loadBalanceInfo: settings["loadbalanceinfo"],
            application: settings["remoteapplicationprogram"],
            usesEntraDesktopSignIn: settings["enablerdsaadauth"] == "1")))
    }
}
