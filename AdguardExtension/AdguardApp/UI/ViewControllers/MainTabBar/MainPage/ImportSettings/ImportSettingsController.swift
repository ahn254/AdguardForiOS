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

import DnsAdGuardSDK
import SafariAdGuardSDK

final class ImportSettingsController: BottomAlertController {

    // MARK: - Outlets

    @IBOutlet var themableLabels: [ThemableLabel]!
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var importButton: RoundRectButton!
    @IBOutlet weak var okButton: RoundRectButton!
    @IBOutlet weak var tableViewHeightConstraint: NSLayoutConstraint!

    // MARK: - Services

    private let theme: ThemeServiceProtocol = ServiceLocator.shared.getService()!

    // MARK: - Properties

    var settings: ImportSettings?
    private var model: ImportSettingsViewModelProtocol?

    // MARK: - ViewController lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        model = initModel(settings: settings)

        updateTheme()
        okButton.isHidden = true
        okButton.makeTitleTextCapitalized()
        okButton.applyStandardGreenStyle()
        importButton.makeTitleTextCapitalized()
        importButton.applyStandardGreenStyle()
        tableView.reloadData()
    }

    override func viewDidLayoutSubviews() {

        super.viewDidLayoutSubviews()

        let contentHeight = tableView.contentSize.height
        let maxHeight = view.frame.size.height - 250
        tableViewHeightConstraint.constant = min(contentHeight, maxHeight)
    }

    // MARK: - IBActions

    @IBAction func importAction(_ sender: Any) {
        importButton.startIndicator()
        importButton.isEnabled = false
        tableView.isUserInteractionEnabled = false
        tableView.alpha = 0.5
        model?.applySettings() {
            DispatchQueue.main.async { [weak self] in
                self?.tableView.reloadData()
                if self?.model?.rows.count ?? 0 > 0 {
                    self?.importButton.stopIndicator()
                    self?.importButton.isHidden = true
                    self?.okButton.isHidden = false
                    self?.tableView.alpha = 1.0
                    self?.tableView.isUserInteractionEnabled = true
                } else {
                    self?.dismiss(animated: true, completion: nil)
                }
            }
        }
    }

    @IBAction func okAction(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }

    // MARK: - Private methods

    private func initModel(settings: ImportSettings?) -> ImportSettingsViewModel? {
        guard let settings = settings else { return nil }

        let dnsProvidersManager: DnsProvidersManagerProtocol = ServiceLocator.shared.getService()!
        let safariProtection: SafariProtectionProtocol = ServiceLocator.shared.getService()!
        let dnsProtection: DnsProtectionProtocol = ServiceLocator.shared.getService()!
        let vpnManager: VpnManagerProtocol = ServiceLocator.shared.getService()!
        let purchaseService: PurchaseServiceProtocol = ServiceLocator.shared.getService()!

        let importService = ImportSettingsService(dnsProvidersManager: dnsProvidersManager, safariProtection: safariProtection, dnsProtection: dnsProtection, vpnManager: vpnManager, purchaseService: purchaseService)

        return ImportSettingsViewModel(settings: settings, importSettingsService: importService, dnsProvidersManager: dnsProvidersManager, safariProtection: safariProtection)
    }
}

// MARK: - ImportSettingsController + UITableViewDataSource

extension ImportSettingsController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return model?.rows.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "ImportSettingsCell") as? ImportSettingsCell else {
            DDLogError("can not instantiate ImportSettingsCell")
            return UITableViewCell()
        }

        guard let row = model?.rows[indexPath.row] else {
            DDLogError("can not find row at index: \(indexPath.row)")
            return UITableViewCell()
        }

        cell.delegate = self
        cell.tag = indexPath.row

        cell.setup(model: row, lastRow: indexPath.row == (model?.rows.count ?? 0) - 1, theme: theme)

        return cell
    }
}

// MARK: - ImportSettingsController + ImportSettingsCellDelegate

extension ImportSettingsController: ImportSettingsCellDelegate {
    func stateChanged(tag: Int, state: Bool) {
        model?.setState(state, forRow: tag)
    }
}

// MARK: - ImportSettingsController + ThemableProtocol

extension ImportSettingsController: ThemableProtocol {
    func updateTheme() {
        contentView.backgroundColor = theme.popupBackgroundColor
        tableView.backgroundColor = theme.popupBackgroundColor
        theme.setupLabels(themableLabels)
        tableView.reloadData()
    }
}
