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

import SafariAdGuardSDK
import DnsAdGuardSDK

/// Protocol for reseting service
protocol SettingsResetServiceProtocol: AnyObject {
    /// Reset safari protection, DNS protection, all in app statistics, providers, purchase info, resources, vpn manager. Post notification that settings were reseted
    /// - Parameter sync: if true than method is executed synchroniously
    /// - Parameter fromUI: if true than a loader will be displayed while settings are being reset
    /// - Parameter resetLicense: if true then current license will be removed
    func resetAllSettings(sync: Bool, fromUI: Bool, resetLicense: Bool)

    /// Reset all statistics info like chart statistics, activity statistics and DNS log statistics. Post notification that statistics were reseted
    func resetAllStatistics()

    /// Reset activity statistics. Return true if successfully reseted
    func resetActivityStatistics() -> Bool

    /// Reset chart statistics.  Return true if successfully reseted
    func resetChartStatistics() -> Bool

    /// Reset DNS log statistics.  Return true if successfully reseted
    func resetDnsLogStatistics() -> Bool
}

// TODO: Need tests for this service

/// Service reset safari protection, DNS protection, all in app statistics, providers, purchase info, resources, vpn manager
final class SettingsResetService: SettingsResetServiceProtocol {

    // MARK: - Private properties

    private let workingQueue =  DispatchQueue(label: "AdGuardApp.ResetQueue")

    private let vpnManager: VpnManagerProtocol
    private let resources: AESharedResourcesProtocol
    private let purchaseService: PurchaseServiceProtocol
    private let safariProtection: SafariProtectionProtocol
    private let dnsProtection: DnsProtectionProtocol
    private let dnsProvidersManager: DnsProvidersManagerProtocol
    private let nativeDnsManager: NativeDnsSettingsManagerProtocol
    private let chartStatistics: ChartStatisticsProtocol
    private let activityStatistics: ActivityStatisticsProtocol
    private let dnsLogStatistics: DnsLogStatisticsProtocol

    // MARK: - Init

    init(vpnManager: VpnManagerProtocol,
         resources: AESharedResourcesProtocol,
         purchaseService: PurchaseServiceProtocol,
         safariProtection: SafariProtectionProtocol,
         dnsProtection: DnsProtectionProtocol,
         dnsProvidersManager: DnsProvidersManagerProtocol,
         nativeDnsManager: NativeDnsSettingsManagerProtocol,
         chartStatistics: ChartStatisticsProtocol,
         activityStatistics: ActivityStatisticsProtocol,
         dnsLogStatistics: DnsLogStatisticsProtocol) {

        self.vpnManager = vpnManager
        self.resources = resources
        self.purchaseService = purchaseService
        self.safariProtection = safariProtection
        self.dnsProtection = dnsProtection
        self.dnsProvidersManager = dnsProvidersManager
        self.nativeDnsManager = nativeDnsManager
        self.chartStatistics = chartStatistics
        self.activityStatistics = activityStatistics
        self.dnsLogStatistics = dnsLogStatistics
    }

    // MARK: - Public methods

    // TODO: - Method looks ugly. We should refactor it
    func resetAllSettings(sync: Bool, fromUI: Bool, resetLicense: Bool) {
        if fromUI {
            DispatchQueue.asyncSafeMain {
                AppDelegate.shared.presentLoadingAlert()
            }
        }
        var syncGroup: DispatchGroup?
        if sync {
            syncGroup = DispatchGroup()
            syncGroup?.enter()
        }
        workingQueue.async { [weak self] in
            guard let self = self else { return }

            DDLogInfo("(SettingsResetService) - resetAllSettings; Start reset")

            // Reset Shared Defaults
            self.resources.reset()
            self.resources.firstRun = false
            self.resources.isMigrationTo4_3Passed = true
            self.resources.isMigrationTo4_3_1Passed = true

            // Reset safari protection
            let group = DispatchGroup()
            group.enter()
            self.safariProtection.reset(withReloadCB: false) { error in
                if let error = error  {
                    DDLogError("(SettingsResetService) - resetAllSettings; Safari protection reset error: \(error)")
                    group.leave()
                    return
                }
                self.enablePredefinedFiltersAndGroups()
                if fromUI {
                    // Do not run this long operation if settings reset hasn't been launched from the UI.
                    // This function downloads filters updates and may simply take too much time.
                    self.updateSafariProtectionMeta()
                }
                group.leave()
            }
            group.wait()

            // Reset VpnManager
            self.vpnManager.removeVpnConfiguration { _ in }

            // Reset Statistics
            self.resetAllStatistics()

            // Reset DNS protection
            self.resetDnsProtection()

            // Install default DNS filter after reset
            let defaultDnsFilterInstaller = DefaultDnsFilterInstaller(resources: self.resources, dnsProtection: self.dnsProtection)
            defaultDnsFilterInstaller.installDefaultDnsFilterIfNeeded()

            // Reset DNS providers
            self.resetDnsProviderManager()

            if #available(iOS 14.0, *) { self.nativeDnsManager.reset() }

            // Reset purchase service
            if resetLicense {
                group.enter()
                self.purchaseService.reset {
                    group.leave()
                }

                group.wait()
            }

            DispatchQueue.main.async {
                AppDelegate.shared.setAppInterfaceStyle()
            }

            // Notify that settings were reset
            NotificationCenter.default.post(name: .resetSettings, object: self)

            syncGroup?.leave()

            if fromUI {
                DispatchQueue.main.async {
                    AppDelegate.shared.setMainPageAsCurrentAndPopToRootControllersEverywhere()
                    DDLogInfo("(SettingsResetService) - resetAllSettings; Reseting is over")
                }
            }
        }
        syncGroup?.wait()
    }

    // MARK: - Statistics reset

    func resetAllStatistics() {
        workingQueue.async { [weak self] in
            guard let self = self else { return }
            DDLogInfo("(SettingsResetService) - resetStatistics; Start reset statistics")

            let activityReset = self.resetActivityStatistics()
            let chartReset = self.resetChartStatistics()
            let dnsLogReset = self.resetDnsLogStatistics()

            DDLogInfo("(SettingsResetService) - resetStatistics; Activity reset = \(activityReset); Chart reset = \(chartReset); DNS log reset = \(dnsLogReset)")
            // Notify that settings were reset
            NotificationCenter.default.post(name: .resetStatistics, object: self)
            DDLogInfo("(SettingsResetService) - resetStatistics; Reset statistics is over")
        }
    }

    func resetActivityStatistics() -> Bool {
        do {
            try activityStatistics.reset()
            DDLogInfo("(SettingsResetService) - resetStatistics; Activity statistics reset successfully")
            return true
        } catch {
            DDLogError("(SettingsResetService) - resetStatistics; Error occurred while resetting activity statistics: \(error)")
            return false
        }
    }

    func resetChartStatistics() -> Bool {
        do {
            try chartStatistics.reset()
            DDLogInfo("(SettingsResetService) - resetStatistics; Chart statistics reset successfully")
            return true

        } catch {
            DDLogError("(SettingsResetService) - resetStatistics; Error occurred while resetting chart statistics: \(error)")
            return false
        }
    }

    func resetDnsLogStatistics() -> Bool {
        do {
            try dnsLogStatistics.reset()
            DDLogInfo("(SettingsResetService) - resetStatistics; Dns log statistics reset successfully")
            return true
        } catch {
            DDLogError("(SettingsResetService) - resetStatistics; Error occurred while resetting dns log statistics: \(error)")
            return false
        }
    }

    //MARK: - Private reset methods

    private func resetDnsProtection() {
        do {
            try dnsProtection.reset()
            DDLogInfo("(SettingsResetService) - resetDnsProtection; Dns Protection reset successfully")
        } catch {
            DDLogError("(SettingsResetService) - resetDnsProtection; Error occurred while resetting dns protection: \(error)")
        }
    }

    private func resetDnsProviderManager() {
        do {
            try dnsProvidersManager.reset()
            DDLogInfo("(SettingsResetService) - resetDnsProviderManager; Dns provider manager reset successfully")
        } catch {
            DDLogError("(SettingsResetService) - resetDnsProviderManager; Error occurred while resetting dns provider manager: \(error)")
        }
    }

    // MARK: - Private methods

    private func enablePredefinedFiltersAndGroups() {
        do {
            try safariProtection.enablePredefinedGroupsAndFilters()
            DDLogInfo("(SettingsResetService) - enablePredefinedFiltersAndGroups; Successfully enable predefined filters and groups after reset safari protection")
        } catch {
            DDLogError("(SettingsResetService) - enablePredefinedFiltersAndGroups; Error occurred while enabling predefined filters and groups on safari protection reset")
        }
    }

    private func updateSafariProtectionMeta() {
        safariProtection.updateFiltersMetaAndLocalizations(true) { result in
            switch result {
            case .success(_):
                DDLogInfo("(SettingsResetService) - updateSafariProtectionMeta; Safari protection meta successfully updated")

            case .error(let error):
                DDLogError("(SettingsResetService) - updateSafariProtectionMeta; On update safari protection meta error occurred: \(error)")
            }

        } onCbReloaded: { error in
            if let error = error {
                DDLogError("(SettingsResetService) - updateSafariProtectionMeta; On reload CB error occurred: \(error)")
                return
            }

            DDLogInfo("(SettingsResetService) - updateSafariProtectionMeta; Successfully reload CB")
        }
    }
}
