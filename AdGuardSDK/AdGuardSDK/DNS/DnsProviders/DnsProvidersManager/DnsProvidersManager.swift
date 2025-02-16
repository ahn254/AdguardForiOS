//
// This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
// Copyright © Adguard Software Limited. All rights reserved.
//
// Adguard for iOS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Adguard for iOS is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Adguard for iOS. If not, see <http://www.gnu.org/licenses/>.
//

import SharedAdGuardSDK

public protocol DnsProvidersManagerProtocol: ResetableSyncProtocol {
    /* Providers */
    var allProviders: [DnsProviderMetaProtocol] { get }
    var predefinedProviders: [DnsProviderProtocol] { get }
    var customProviders: [CustomDnsProviderProtocol] { get }

    /* Active */
    var activeDnsProvider: DnsProviderMetaProtocol { get }
    var activeDnsServer: DnsServerMetaProtocol { get }

    /**
     This method should be called when implementation changes
     All inner objects will be reconstructed according to implementation
     */
    func update(dnsImplementation: DnsImplementation)

    /**
     Makes provider with **id** active

     All predefined providers can have multiple DNS servers so to reveal the server to make active
     we need **provider id** to find a provider and **server id** to find a server
     - Parameter id: Unique provider identifier
     - Parameter type: Unique identifier of server to select
     - Throws: throws error if provider or server id is invalid
     */
    func selectProvider(withId id: Int, serverId: Int) throws

    /**
     Adds new custom provider to storage
     - Parameter name: Name of provider to add
     - Parameter upstreams: List of provider upstreams
     - Parameter selectAsCurrent: If true than provider will be set as active
     - Throws:  Throws an error if upstreams are invalid or have different protocols
                or custom dns provider with the same upstream exists
     */
    func addCustomProvider(name: String, upstreams: [String], selectAsCurrent: Bool, isMigration: Bool) throws

    /**
     Updates custom provider in the storage
     - Parameter id: Unique identifier of custom DNS provider that should be updated
     - Parameter newName: New name of provider to update
     - Parameter newUpstreams: New upstreams of provider to update
     - Parameter selectAsCurrent: If true than provider will be set as active
     - Throws:  Throws an error if custom provider with the specified **id** is not in the storage
                 or another custom dns provider with the same upstream exists
     */
    func updateCustomProvider(withId id: Int, newName: String, newUpstreams: [String], selectAsCurrent: Bool) throws

    /**
     Removes custom provider by its **id** from storage

     If current provider is removed than the default one or AdGuard DoH will be set depending on the
     current DNS implementation

     - Parameter id: Unique identifier of custom DNS provider that should be removed from the storage
     - Throws: Throws an error if custom provider with passed **id** is not in the storage
     */
    func removeCustomProvider(withId id: Int) throws
}

final public class DnsProvidersManager: DnsProvidersManagerProtocol {

    // MARK: - Internal variables

    public var allProviders: [DnsProviderMetaProtocol] { predefinedProviders + customProviders }
    public var predefinedProviders: [DnsProviderProtocol]
    public var customProviders: [CustomDnsProviderProtocol]

    public var activeDnsProvider: DnsProviderMetaProtocol
    public var activeDnsServer: DnsServerMetaProtocol

    // MARK: - Private variables

    /* Services */
    private let configuration: DnsConfigurationProtocol
    private let userDefaults: UserDefaultsStorageProtocol
    private let customProvidersStorage: CustomDnsProvidersStorageProtocol
    private let providersVendor: DnsProvidersVendorProtocol

    // MARK: - Initialization

    public convenience init(configuration: DnsConfigurationProtocol, userDefaults: UserDefaults, networkUtils: NetworkUtilsProtocol) throws {
        let userDefaultsStorage = UserDefaultsStorage(storage: userDefaults)
        try self.init(configuration: configuration, userDefaults: userDefaultsStorage, networkUtils: networkUtils)
    }

    convenience init(configuration: DnsConfigurationProtocol, userDefaults: UserDefaultsStorageProtocol, networkUtils: NetworkUtilsProtocol) throws {
        let customProvidersStorage = CustomDnsProvidersStorage(userDefaults: userDefaults, networkUtils: networkUtils,configuration: configuration)
        let predefinedDnsProviders = try PredefinedDnsProvidersDecoder(currentLocale: configuration.currentLocale)
        self.init(
            configuration: configuration,
            userDefaults: userDefaults,
            customProvidersStorage: customProvidersStorage,
            predefinedProviders: predefinedDnsProviders
        )
    }

    // Init for tests
    init(configuration: DnsConfigurationProtocol,
         userDefaults: UserDefaultsStorageProtocol,
         customProvidersStorage: CustomDnsProvidersStorageProtocol,
         predefinedProviders: PredefinedDnsProvidersDecoderProtocol) {
        Logger.logInfo("(DnsProvidersManager) - init start")
        self.configuration = configuration
        self.userDefaults = userDefaults
        self.customProvidersStorage = customProvidersStorage
        self.providersVendor = DnsProvidersVendor(predefinedProviders: predefinedProviders, customProvidersStorage: self.customProvidersStorage)

        let providersWithState = providersVendor.getProvidersWithState(for: configuration.dnsImplementation, activeDns: userDefaults.activeDnsInfo)

        self.predefinedProviders = providersWithState.predefined
        self.customProviders = providersWithState.custom
        self.activeDnsProvider = providersWithState.activeDnsProvider
        self.activeDnsServer = providersWithState.activeDnsServer
        Logger.logInfo("(DnsProvidersManager) - init end")
    }

    // MARK: - Public methods

    public func update(dnsImplementation: DnsImplementation) {
        Logger.logInfo("(DnsProvidersManager) - updateDnsImplementation; Changed to \(dnsImplementation)")
        configuration.dnsImplementation = dnsImplementation
        reinitializeProviders()
    }

    public func selectProvider(withId id: Int, serverId: Int) throws {
        Logger.logInfo("(DnsProvidersManager) - selectProvider; Selecting provider with id=\(id) serverId=\(serverId)")

        guard let provider = allProviders.first(where: { $0.providerId == id }) else {
            throw DnsProviderError.invalidProvider(providerId: id)
        }

        guard provider.dnsServers.contains(where: { $0.id == serverId }) else {
            throw DnsProviderError.invalidCombination(providerId: id, serverId: serverId)
        }

        let newActiveDnsInfo = DnsProvidersManager.ActiveDnsInfo(providerId: id, serverId: serverId)
        userDefaults.activeDnsInfo = newActiveDnsInfo
        reinitializeProviders()

        Logger.logInfo("(DnsProvidersManager) - selectProvider; Selected provider with id=\(id) serverId=\(serverId)")
    }

    // TODO: - It's a crutch, should be refactored
    /// isMigration parameter is a crutch to quickly migrate custom DNS providers without checking their upstreams
    public func addCustomProvider(name: String, upstreams: [String], selectAsCurrent: Bool, isMigration: Bool) throws {
        Logger.logInfo("(DnsProvidersManager) - addCustomProvider; Trying to add custom provider with name=\(name), upstreams=\(upstreams.joined(separator: "; ")) selectAsCurrent=\(selectAsCurrent)")

        // check server exists
        let servers = customProvidersStorage.providers.map { $0.server }
        let exists = servers.contains { server in
            let serverUpstreams = server.upstreams.map { $0.upstream }
            return serverUpstreams == upstreams
        }
        if exists {
            throw DnsProviderError.dnsProviderExists(upstreams: upstreams)
        }

        let ids = try customProvidersStorage.addCustomProvider(name: name, upstreams: upstreams, isMigration: isMigration)
        if selectAsCurrent {
            userDefaults.activeDnsInfo = DnsProvidersManager.ActiveDnsInfo(providerId: ids.providerId, serverId: ids.serverId)
        }
        reinitializeProviders()


        Logger.logInfo("(DnsProvidersManager) - addCustomProvider; Added custom provider with name=\(name), upstreams=\(upstreams.joined(separator: "; ")) selectAsCurrent=\(selectAsCurrent)")
    }

    public func updateCustomProvider(withId id: Int, newName: String, newUpstreams: [String], selectAsCurrent: Bool) throws {
        Logger.logInfo("(DnsProvidersManager) - updateCustomProvider; Trying to update custom provider with id=\(id) name=\(newName), upstreams=\(newUpstreams.joined(separator: "; ")) selectAsCurrent=\(selectAsCurrent)")

        // check another server with given upstream exists
        let servers = customProvidersStorage.providers.compactMap {
            return $0.providerId == id ? nil : $0.server
        }
        let exists = servers.contains { server in
            let serverUpstreams = server.upstreams.map { $0.upstream }
            return serverUpstreams == newUpstreams
        }

        if exists {
            throw DnsProviderError.dnsProviderExists(upstreams: newUpstreams)
        }

        try customProvidersStorage.updateCustomProvider(withId: id, newName: newName, newUpstreams: newUpstreams)
        if selectAsCurrent, let provider = customProviders.first(where: { $0.providerId == id }) {
            userDefaults.activeDnsInfo = DnsProvidersManager.ActiveDnsInfo(providerId: provider.providerId, serverId: provider.server.id)
        }
        reinitializeProviders()

        Logger.logInfo("(DnsProvidersManager) - updateCustomProvider; Updated custom provider with id=\(id) name=\(newName), upstreams=\(newUpstreams.joined(separator: "; ")) selectAsCurrent=\(selectAsCurrent)")
    }

    public func removeCustomProvider(withId id: Int) throws {
        Logger.logInfo("(DnsProvidersManager) - removeCustomProvider; Trying to remove provider with id=\(id)")

        try customProvidersStorage.removeCustomProvider(withId: id)

        let activeProviderId = userDefaults.activeDnsInfo.providerId
        if id == activeProviderId {
            let defaultProviderId = PredefinedDnsProvider.systemDefaultProviderId
            let defaultServerId = PredefinedDnsServer.systemDefaultServerId
            userDefaults.activeDnsInfo = DnsProvidersManager.ActiveDnsInfo(providerId: defaultProviderId, serverId: defaultServerId)
        }
        reinitializeProviders()

        Logger.logInfo("(DnsProvidersManager) - removeCustomProvider; Removed provider with id=\(id)")
    }

    public func reset() throws {
        Logger.logInfo("(DnsProvidersManager) - reset; Start")

        let defaultProviderId = PredefinedDnsProvider.systemDefaultProviderId
        let defaultServerId = PredefinedDnsServer.systemDefaultServerId
        userDefaults.activeDnsInfo = DnsProvidersManager.ActiveDnsInfo(providerId: defaultProviderId, serverId: defaultServerId)

        try! customProvidersStorage.reset()
        reinitializeProviders()

        Logger.logInfo("(DnsProvidersManager) - reset; Finish")
    }

    // MARK: - Private methods

    private func reinitializeProviders() {
        let providersWithState = providersVendor.getProvidersWithState(for: configuration.dnsImplementation,
                                                                       activeDns: userDefaults.activeDnsInfo)

        self.predefinedProviders = providersWithState.predefined
        self.customProviders = providersWithState.custom
        self.activeDnsProvider = providersWithState.activeDnsProvider
        self.activeDnsServer = providersWithState.activeDnsServer
    }
}

// MARK: - DnsProvidersManager + Helper objects

extension DnsProvidersManager {

    struct ActiveDnsInfo: Codable {
        let providerId: Int
        let serverId: Int
    }

    public enum DnsProviderError: Error, CustomDebugStringConvertible {
        case invalidProvider(providerId: Int)
        case invalidCombination(providerId: Int, serverId: Int)
        case unsupportedProtocol(prot: DnsProtocol)
        case dnsProviderExists(upstreams: [String])

        public var debugDescription: String {
            switch self {
            case .invalidProvider(let providerId): return "DNS provider with id=\(providerId) doesn't exist"
            case .invalidCombination(let providerId, let serverId): return "DNS provider with id=\(providerId) doesn't have server with id=\(serverId)"
            case .unsupportedProtocol(let prot): return "Native DNS implementation doesn't support \(prot.rawValue)"
            case .dnsProviderExists(let upstreams): return "Dns provider with upstreams=\(upstreams) exists"
            }
        }
    }
}

// MARK: - UserDefaultsStorageProtocol + DnsProvidersManager variables

fileprivate extension UserDefaultsStorageProtocol {
    private var activeDnsInfoKey: String { "DnsAdGuardSDK.activeDnsInfoKey" }

    var activeDnsInfo: DnsProvidersManager.ActiveDnsInfo {
        get {
            if let infoData = storage.value(forKey: activeDnsInfoKey) as? Data {
                let decoder = JSONDecoder()
                if let info = try? decoder.decode(DnsProvidersManager.ActiveDnsInfo.self, from: infoData) {
                    return info
                }
            }
            let defaultProviderId = PredefinedDnsProvider.systemDefaultProviderId
            let defaultServerId = PredefinedDnsServer.systemDefaultServerId
            return DnsProvidersManager.ActiveDnsInfo(providerId: defaultProviderId, serverId: defaultServerId)
        }
        set {
            let encoder = JSONEncoder()
            if let infoData = try? encoder.encode(newValue) {
                storage.setValue(infoData, forKey: activeDnsInfoKey)
                return
            }
            let defaultProviderId = PredefinedDnsProvider.systemDefaultProviderId
            let defaultServerId = PredefinedDnsServer.systemDefaultServerId
            let info = DnsProvidersManager.ActiveDnsInfo(providerId: defaultProviderId, serverId: defaultServerId)
            storage.setValue(info, forKey: activeDnsInfoKey)
        }
    }
}
