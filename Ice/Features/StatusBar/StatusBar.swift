//
//  StatusBar.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Manages the state of the items in the status bar.
class StatusBar: ObservableObject {
    /// A representation of a section in a status bar.
    enum Section: Int {
        case alwaysVisible
        case hidden
        case alwaysHidden

        /// A user-visible name that describes the section.
        var name: String {
            switch self {
            case .alwaysVisible: return "Always Visible"
            case .hidden: return "Hidden"
            case .alwaysHidden: return "Always Hidden"
            }
        }
    }

    /// The shared status bar singleton.
    static let shared = StatusBar()

    private var cancellables = Set<AnyCancellable>()

    private var lastSavedControlItemsHash: Int?

    /// Set to `true` to tell the status bar to save its control items.
    @Published var needsSaveControlItems = false

    /// The current control items, unsorted.
    private(set) var controlItems = [ControlItem]() {
        willSet {
            for controlItem in controlItems {
                controlItem.statusBar = nil
            }
        }
        didSet {
            if validateControlItemCount() {
                for controlItem in controlItems {
                    controlItem.statusBar = self
                }
            }
            configureCancellables()
            needsSaveControlItems = true
        }
    }

    /// The current control items, sorted by their position in the status bar.
    var sortedControlItems: [ControlItem] {
        controlItems.sorted {
            ($0.position ?? 0) < ($1.position ?? 0)
        }
    }

    /// Dynamically constructed menu to show when a control item belonging to
    /// the status bar is right-clicked.
    @MenuBuilder
    var menu: NSMenu {
        MenuComponents.Title(Constants.appName)
        MenuComponents.ItemGroup {
            if controlItem(forSection: .hidden) != nil {
                let actionString = isSectionHidden(.hidden) ? "Show" : "Hide"
                let sectionString = "\"\(Section.hidden.name)\" Section"
                MenuItems.Item(title: "\(actionString) \(sectionString)") { [weak self] in
                    self?.toggle(section: .hidden)
                }
            }
            if controlItem(forSection: .alwaysHidden) != nil {
                let actionString = isSectionHidden(.alwaysHidden) ? "Show" : "Hide"
                let sectionString = "\"\(Section.alwaysHidden.name)\" Section"
                MenuItems.Item(title: "\(actionString) \(sectionString)") { [weak self] in
                    self?.toggle(section: .alwaysHidden)
                }
            }
        }
        MenuComponents.ItemGroup(separatorPlacement: [.before, .after]) {
            MenuItems.Item(
                title: "Settings…",
                key: ",",
                modifiers: .command,
                action: #selector(AppDelegate.openSettingsWindow)
            )
        }
        MenuComponents.ItemGroup {
            MenuItems.Item(
                title: "Quit \(Constants.appName)",
                key: "q",
                modifiers: .command,
                action: #selector(NSApp.terminate)
            )
        }
    }

    private init() {
        configureCancellables()
    }

    /// Performs the initial setup of the status bar's control item list.
    func initializeControlItems() {
        defer {
            if lastSavedControlItemsHash == nil {
                lastSavedControlItemsHash = controlItems.hashValue
            }
        }

        guard controlItems.isEmpty else {
            return
        }

        controlItems = Defaults.serializedControlItems.enumerated().map { index, entry in
            do {
                let dictionary = [entry.key: entry.value]
                return try DictionarySerialization.value(ofType: ControlItem.self, from: dictionary)
            } catch {
                Logger.statusBar.error("Error decoding control item: \(error)")
                return ControlItem(autosaveName: entry.key, position: CGFloat(index))
            }
        }
    }

    /// Save all control items in the status bar to persistent storage.
    func saveControlItems() {
        if
            let lastSavedControlItemsHash,
            controlItems.hashValue == lastSavedControlItemsHash
        {
            // control items haven't changed; no need to save
            needsSaveControlItems = false
            return
        }
        do {
            Defaults.serializedControlItems = try controlItems.reduce(into: [:]) { serialized, item in
                let dictionary = try DictionarySerialization.dictionary(from: item)
                serialized.merge(dictionary, uniquingKeysWith: { $1 })
            }
            lastSavedControlItemsHash = controlItems.hashValue
            needsSaveControlItems = false
        } catch {
            Logger.statusBar.error("Error encoding control item: \(error)")
        }
    }

    /// Performs validation on the current control item count, adding or
    /// removing items as needed, and returns a Boolean value indicating
    /// whether the count was valid.
    private func validateControlItemCount() -> Bool {
        let enableAlwaysHidden = Defaults.enableAlwaysHidden
        if controlItems.isEmpty {
            // fast path; don't do work if we don't have to
            var items = [
                ControlItem(position: 0),
                ControlItem(position: 1),
            ]
            if enableAlwaysHidden {
                items.append(ControlItem())
            }
            controlItems = items
            return false // count was invalid
        }
        // expected count varies based on whether the user has enabled
        // the always-hidden section
        let expectedCount = enableAlwaysHidden ? 3 : 2
        let actualCount = controlItems.count
        if actualCount == expectedCount {
            // count is already valid, so no need to do anything more
            return true
        }
        if actualCount < expectedCount {
            // add new items up to the expected count
            if enableAlwaysHidden {
                // subtract 1 from expected count and handle always-hidden
                // item separately
                controlItems += {
                    var items = (actualCount..<(expectedCount - 1)).map { index in
                        ControlItem(position: CGFloat(index))
                    }
                    // don't assign an initial position so that the item gets
                    // placed at the far end of the status bar
                    items.append(ControlItem())
                    return items
                }()
            } else {
                // always-hidden section is disabled, so don't worry about
                // separate handling
                controlItems += (actualCount..<expectedCount).map { index in
                    ControlItem(position: CGFloat(index))
                }
            }
        } else if actualCount > expectedCount {
            // remove extra items down to the expected count
            controlItems = Array(controlItems[..<expectedCount])
        }
        // if we made it this far, count was invalid
        return false
    }

    /// Set up a series of cancellables to respond to key changes in the
    /// status bar's state.
    private func configureCancellables() {
        // cancel and remove all current cancellables
        for cancellable in cancellables {
            cancellable.cancel()
        }
        cancellables.removeAll()

        // update all control items when the position of one changes
        Publishers.MergeMany(controlItems.map { $0.$position })
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                for controlItem in controlItems {
                    controlItem.updateStatusItem()
                }
            }
            .store(in: &cancellables)

        // save control items when a flag is set, avoiding rapid resaves
        $needsSaveControlItems
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink { [weak self] needsSave in
                if needsSave {
                    self?.saveControlItems()
                }
            }
            .store(in: &cancellables)
    }

    /// Returns the status bar section for the given control item.
    func section(for controlItem: ControlItem) -> Section? {
        sortedControlItems.enumerated().first { $0.element == controlItem }.flatMap { pair in
            Section(rawValue: pair.offset)
        }
    }

    /// Returns the control item for the given status bar section.
    func controlItem(forSection section: Section) -> ControlItem? {
        let index = section.rawValue
        guard index < controlItems.count else {
            return nil
        }
        return sortedControlItems[index]
    }

    /// Returns a Boolean value that indicates whether the given section
    /// is hidden by its control item.
    func isSectionHidden(_ section: Section) -> Bool {
        guard let item = controlItem(forSection: section) else {
            return false
        }
        switch item.state {
        case .hideItems: return true
        case .showItems: return false
        }
    }

    /// Shows the status items in the given section.
    func show(section: Section) {
        switch section {
        case .alwaysVisible, .hidden:
            controlItem(forSection: .alwaysVisible)?.state = .showItems
            controlItem(forSection: .hidden)?.state = .showItems
        case .alwaysHidden:
            show(section: .hidden)
            controlItem(forSection: .alwaysHidden)?.state = .showItems
        }
    }

    /// Hides the status items in the given section.
    func hide(section: Section) {
        switch section {
        case .alwaysVisible, .hidden:
            controlItem(forSection: .alwaysVisible)?.state = .hideItems(isExpanded: false)
            controlItem(forSection: .hidden)?.state = .hideItems(isExpanded: true)
            hide(section: .alwaysHidden)
        case .alwaysHidden:
            controlItem(forSection: .alwaysHidden)?.state = .hideItems(isExpanded: true)
        }
    }

    /// Toggles the visibility of the status items in the given section.
    func toggle(section: Section) {
        guard let item = controlItem(forSection: section) else {
            return
        }
        switch item.state {
        case .hideItems:
            show(section: section)
        case .showItems:
            hide(section: section)
        }
    }
}