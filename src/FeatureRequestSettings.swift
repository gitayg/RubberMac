import AppKit

extension AppDelegate {
    // Sections added at the end of the General page.
    func featureRequestSections(_ facts: SettingsFacts) -> [SettingsSection] {
        [SettingsSection(title: "Ideas", rows: [
            button("Send a Feature Request…", "Write", #selector(writeFeatureRequest), closes: true),
        ])]
    }

    @objc func writeFeatureRequest() {
        FeatureRequest.open()
    }
}
