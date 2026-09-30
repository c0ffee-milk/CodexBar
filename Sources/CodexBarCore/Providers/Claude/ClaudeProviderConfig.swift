import Foundation

extension ProviderConfig {
    public var claudeStatusLineSelected: Bool? {
        get { self.extensionValue(forKey: "claudeStatusLineSelected") }
        set { self.setExtensionValue(newValue, forKey: "claudeStatusLineSelected") }
    }

    public var claudeStatusLineAutoFallback: Bool? {
        get { self.extensionValue(forKey: "claudeStatusLineAutoFallback") }
        set { self.setExtensionValue(newValue, forKey: "claudeStatusLineAutoFallback") }
    }

    public var claudeStatusLineCachePath: String? {
        get { self.extensionValue(forKey: "claudeStatusLineCachePath") }
        set { self.setExtensionValue(newValue, forKey: "claudeStatusLineCachePath") }
    }

    public var claudeWorkspaceSpendEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeWorkspaceSpendEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeWorkspaceSpendEnabled") }
    }

    public var claudeSwapEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeSwapEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapEnabled") }
    }

    public var claudeSwapShowSingleAccount: Bool? {
        get { self.extensionValue(forKey: "claudeSwapShowSingleAccount") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapShowSingleAccount") }
    }

    public var claudeSwapExecutablePath: String? {
        get { self.extensionValue(forKey: "claudeSwapExecutablePath") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapExecutablePath") }
    }

    public var sanitizedClaudeSwapExecutablePath: String? {
        SettingsValue.cleaned(self.claudeSwapExecutablePath)
    }
}
