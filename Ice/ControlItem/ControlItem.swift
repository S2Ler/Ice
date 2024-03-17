//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// A status item that controls the visibility of a section
/// in the menu bar.
final class ControlItem: ObservableObject {
    enum Identifier: String, Hashable, Codable {
        case iceIcon = "IceIcon"
        case hidden = "HiddenItem"
        case alwaysHidden = "AlwaysHiddenItem"
    }

    enum HidingState: Int, Hashable, Codable {
        case hideItems
        case showItems
    }

    enum Lengths {
        static let standard: CGFloat = 25
        static let expanded: CGFloat = 10_000
    }

    private static let sectionStorage = ObjectAssociation<MenuBarSection>()

    private var cancellables = Set<AnyCancellable>()

    private weak var appState: AppState?

    private let statusItem: NSStatusItem

    /// A Boolean value that indicates whether the control
    /// item is visible.
    @Published var isVisible: Bool

    /// The hiding state of the control item.
    @Published var state: HidingState

    /// The frame of the control item's window.
    @Published private(set) var windowFrame: CGRect?

    /// The control item's identifier.
    let identifier: Identifier

    /// The menu bar section associated with the control item.
    private weak var section: MenuBarSection? {
        appState?.menuBarManager.sections.first { $0.controlItem === self }
    }

    /// The control item's autosave name.
    var autosaveName: String {
        statusItem.autosaveName
    }

    /// The identifier of the control item's window.
    var windowID: CGWindowID? {
        guard let window = statusItem.button?.window else {
            return nil
        }
        return CGWindowID(window.windowNumber)
    }

    /// A Boolean value that indicates whether the control item
    /// is a section divider.
    var isSectionDivider: Bool {
        guard let section else {
            return false
        }
        return section.name != .visible
    }

    /// Creates a control item with the given autosave name, position,
    /// and hiding state.
    ///
    /// - Parameters:
    ///   - autosaveName: The control item's autosave name.
    ///   - position: The position of the control item in the menu bar.
    ///     Pass `nil` to add the control item to the end of the menu bar.
    ///   - state: The hiding state of the control item.
    init(identifier: Identifier, position: CGFloat?, state: HidingState? = nil) {
        let autosaveName = identifier.rawValue

        // if the isVisible property has been previously set, it will have
        // been stored in user defaults; if a status item is created in an
        // invisible state, its preferred position is deleted; to prevent
        // this, cache the current visibility, if any, and delete it from
        // defaults; then, initialize the status item and set its visibility
        // to the cached value
        let cachedIsVisible = StatusItemDefaults[.isVisible, autosaveName]
        StatusItemDefaults[.isVisible, autosaveName] = nil

        if let position {
            // set the preferred position first to ensure that
            // the status item appears in the correct position
            StatusItemDefaults[.preferredPosition, autosaveName] = position
        }

        self.statusItem = NSStatusBar.system.statusItem(withLength: Lengths.standard)
        self.statusItem.autosaveName = autosaveName
        self.isVisible = statusItem.isVisible
        self.state = state ?? .showItems
        self.identifier = identifier

        // NOTE: cache needs to be restored after the status item
        // is created, but before the call to configureStatusItem()
        if let cachedIsVisible {
            self.isVisible = cachedIsVisible
        }

        configureStatusItem()
    }

    deinit {
        // removing the status item has the unwanted side effect 
        // of deleting the preferred position; cache and restore
        // after removing
        let autosaveName = autosaveName
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        defer {
            StatusItemDefaults[.preferredPosition, autosaveName] = cached
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem(with: state)
        }
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(performAction)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $state
            .sink { [weak self] state in
                self?.updateStatusItem(with: state)
            }
            .store(in: &c)

        $isVisible
            .removeDuplicates()
            .sink { [weak self] isVisible in
                guard let self else {
                    return
                }
                var deferredBlock: (() -> Void)?
                if !isVisible {
                    // setting the status item to invisible has the unwanted
                    // side effect of deleting the preferred position; cache
                    // and restore afterwards
                    let autosaveName = autosaveName
                    let cached = StatusItemDefaults[.preferredPosition, autosaveName]
                    deferredBlock = {
                        StatusItemDefaults[.preferredPosition, autosaveName] = cached
                    }
                }
                statusItem.isVisible = isVisible
                appState?.menuBarManager.needsSave = true
                deferredBlock?()
            }
            .store(in: &c)

        statusItem.publisher(for: \.isVisible)
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.isVisible = isVisible
            }
            .store(in: &c)

        if let window = statusItem.button?.window {
            window.publisher(for: \.frame)
                .sink { [weak self, weak window] frame in
                    guard
                        let self,
                        let screen = window?.screen,
                        screen.frame.intersects(frame)
                    else {
                        return
                    }
                    windowFrame = frame
                }
                .store(in: &c)
        }

        if let appState {
            appState.settingsManager.generalSettingsManager.$showIceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] showIceIcon in
                    guard
                        let self,
                        !isSectionDivider
                    else {
                        return
                    }
                    isVisible = showIceIcon
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$iceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$customIceIconIsTemplate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$showSectionDividers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] shouldShow in
                    guard
                        let self,
                        isSectionDivider,
                        state == .showItems
                    else {
                        return
                    }
                    isVisible = shouldShow
                }
                .store(in: &c)
        }

        cancellables = c
    }

    private func updateStatusItem(with state: HidingState) {
        guard
            let appState,
            let section,
            let button = statusItem.button
        else {
            return
        }

        defer {
            appState.menuBarManager.needsSave = true
        }

        switch section.name {
        case .visible:
            statusItem.length = Lengths.standard
            // enable cell, as it may have been previously disabled
            button.cell?.isEnabled = true
            let icon = appState.settingsManager.generalSettingsManager.iceIcon
            // we can usually just set the image directly from the icon
            button.image = switch state {
            case .hideItems: icon.hidden.nsImage(for: appState)
            case .showItems: icon.visible.nsImage(for: appState)
            }
            if
                case .custom = icon.name,
                let originalImage = button.image
            {
                // custom icons need to be resized to fit inside the button
                let originalWidth = originalImage.size.width
                let originalHeight = originalImage.size.height
                let ratio = max(originalWidth / 25, originalHeight / 17)
                let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
                button.image = originalImage.resized(to: newSize)
            }
        case .hidden, .alwaysHidden:
            switch state {
            case .hideItems:
                isVisible = true
                statusItem.length = Lengths.expanded
                // prevent the cell from highlighting while expanded
                button.cell?.isEnabled = false
                // cell still sometimes briefly flashes on expansion
                // unless manually unhighlighted
                button.isHighlighted = false
                button.image = nil
            case .showItems:
                isVisible = appState.settingsManager.advancedSettingsManager.showSectionDividers
                statusItem.length = Lengths.standard
                // enable cell, as it may have been previously disabled
                button.cell?.isEnabled = true
                // set the image based on section name and state
                switch section.name {
                case .hidden:
                    button.image = ControlItemImage.builtin(.chevronLarge).nsImage(for: appState)
                case .alwaysHidden:
                    button.image = ControlItemImage.builtin(.chevronSmall).nsImage(for: appState)
                case .visible: break
                }
            }
        }
    }

    @objc private func performAction() {
        guard
            let appState,
            let event = NSApp.currentEvent
        else {
            return
        }
        switch event.type {
        case .leftMouseUp:
            let advancedSettingsManager = appState.settingsManager.advancedSettingsManager
            if 
                NSEvent.modifierFlags == advancedSettingsManager.secondaryActionModifier.nsEventFlags,
                advancedSettingsManager.secondaryAction.perform(with: appState)
            {
                break
            } else {
                section?.toggle()
            }
        case .rightMouseUp:
            statusItem.showMenu(createMenu(with: appState))
        default:
            break
        }
    }

    private func createMenu(with appState: AppState) -> NSMenu {
        let menu = NSMenu(title: Constants.appName)

        // add menu items to toggle the hidden and always-hidden 
        // sections, if each section is enabled
        let sectionNames: [MenuBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard let section = appState.menuBarManager.section(withName: name) else {
                continue
            }
            let item = NSMenuItem(
                title: "\(section.isHidden ? "Show" : "Hide") \"\(name.rawValue)\" Section",
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.target = self
            Self.sectionStorage[item] = section
            let hotkeySettingsManager = appState.settingsManager.hotkeySettingsManager
            switch name {
            case .visible:
                break
            case .hidden:
                if 
                    let hotkey = hotkeySettingsManager.hotkey(withAction: .toggleHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            case .alwaysHidden:
                if
                    let hotkey = hotkeySettingsManager.hotkey(withAction: .toggleAlwaysHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(Constants.appName)",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        Self.sectionStorage[menuItem]?.toggle()
    }

    @objc private func checkForUpdates() {
        guard 
            let appState,
            let appDelegate = appState.appDelegate
        else {
            return
        }
        // open the settings window in case an alert needs to be displayed
        appDelegate.openSettingsWindow()
        appState.updatesManager.checkForUpdates()
    }

    /// Assigns the app state to the control item.
    func assignAppState(_ appState: AppState) {
        guard self.appState == nil else {
            Logger.controlItem.warning("Multiple attempts made to assign app state")
            return
        }
        self.appState = appState
        configureCancellables()
        updateStatusItem(with: state)
    }
}

// MARK: ControlItem: Codable
extension ControlItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case identifier
        case state
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: container.decode(Identifier.self, forKey: .identifier),
            position: nil,
            state: container.decode(HidingState.self, forKey: .state)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(state, forKey: .state)
    }
}

// MARK: - StatusItemDefaultsKey

/// Keys used to look up user defaults for status items.
private struct StatusItemDefaultsKey<Value> {
    let rawValue: String
}

extension StatusItemDefaultsKey<CGFloat> {
    static let preferredPosition = StatusItemDefaultsKey(rawValue: "Preferred Position")
}

extension StatusItemDefaultsKey<Bool> {
    static let isVisible = StatusItemDefaultsKey(rawValue: "Visible")
}

// MARK: - StatusItemDefaults

/// Proxy getters and setters for a status item's user default values.
private enum StatusItemDefaults {
    private static func stringKey<Value>(
        forKey key: StatusItemDefaultsKey<Value>,
        autosaveName: String
    ) -> String {
        return "NSStatusItem \(key.rawValue) \(autosaveName)"
    }

    /// Accesses the value associated with the specified key and autosave name.
    static subscript<Value>(
        key: StatusItemDefaultsKey<Value>,
        autosaveName: String
    ) -> Value? {
        get {
            let key = stringKey(forKey: key, autosaveName: autosaveName)
            return UserDefaults.standard.object(forKey: key) as? Value
        }
        set {
            let key = stringKey(forKey: key, autosaveName: autosaveName)
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let controlItem = Logger(category: "ControlItem")
}
