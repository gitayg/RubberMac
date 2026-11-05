// Apps where PC-style key remaps must stay out of the way.
enum AppLists {
    // Ctrl-C interrupts, Ctrl-Z suspends, Home/End scroll the scrollback.
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

    // Editors with a built-in terminal, where Ctrl-C must still interrupt.
    static let editorsWithTerminal: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    // Remote desktops and VMs pass PC keys through to Windows themselves.
    static let remote: Set<String> = [
        "com.microsoft.rdc.macos", "com.vmware.fusion", "com.utmapp.UTM", "com.teamviewer.TeamViewer",
        "com.apple.ScreenSharing", "com.parallels.desktop.console",
    ]
}
