import AppKit

extension AppDelegate {
    // At the top of the General and Keyboard pages, only while the notice is up.
    func secureInputSections(_ facts: SettingsFacts) -> [SettingsSection] {
        secureInputSections(SecureInputMonitor.shared.notice)
    }

    func secureInputSections(_ notice: SecureInput.Notice?) -> [SettingsSection] {
        guard let notice else { return [] }
        let row = notice.button.map { button(notice.title, $0, #selector(showSecureInputHolder), note: notice.body, closes: true) }
            ?? SettingsRow(title: notice.title, note: notice.body, control: .none)
        return [SettingsSection(title: SecureInput.Notice.sectionTitle, rows: [row])]
    }

    // Brings the app holding Secure Input to the front, where its password or sign-in prompt may be hiding.
    @objc func showSecureInputHolder() {
        guard let pid = SecureInputMonitor.shared.holder?.pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
        app.activate()
    }
}
