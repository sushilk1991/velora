import AppKit

/// Ref-counted activation policy. While any real window (Settings,
/// onboarding) is open the app must be a REGULAR app — that's what puts
/// "Velora / File / Edit…" in the menu bar and a Dock icon under the window
/// (user report: focusing Settings showed no app menus, unlike every other
/// app). When the last window closes the app returns to the menubar-accessory
/// policy. A plain set/restore in each window controller would break with two
/// windows open: closing either one would yank the policy out from under the
/// other.
enum AppActivation {
    private static var holds = 0

    static func acquireRegular() {
        holds += 1
        NSApp.setActivationPolicy(.regular)
    }

    static func releaseRegular() {
        holds = max(0, holds - 1)
        if holds == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// The app's main menu. A menubar-accessory app has none by default, so
/// beyond the missing app menus the standard Edit shortcuts (⌘C/⌘V/⌘A/⌘Z)
/// had no menu items to resolve against in Settings text fields. Built once
/// at launch; the menu bar shows it whenever the app is active as a regular
/// app. Every toolbar-ish control in the app keeps a menu counterpart here
/// (HIG: menus are the authoritative command surface).
enum MainMenu {
    /// `target` is the AppDelegate providing the @objc actions; standard
    /// selectors (close, copy, minimize…) stay nil-targeted so the responder
    /// chain resolves them.
    static func install(target: AnyObject) {
        let main = NSMenu()

        // App menu (title is replaced by the process name at display time).
        let appMenu = NSMenu(title: "Velora")
        appMenu.addItem(item("About Velora", #selector(AppDelegate.menuOpenAbout), target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(item(
            "Settings…", #selector(AppDelegate.menuOpenSettings), target: target, key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Velora", #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(item(
            "Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
            key: "h", modifiers: [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Velora", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenuItem(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))
        main.addItem(submenuItem(fileMenu))

        // Standard first-responder editing commands — these are what make the
        // system shortcuts work inside every text field the app hosts.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Undo", Selector(("undo:")), key: "z"))
        editMenu.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item("Delete", #selector(NSText.delete(_:))))
        editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        main.addItem(submenuItem(editMenu))

        // View — the sidebar toggle's menu counterpart (HIG sidebar rule);
        // AppDelegate retitles it Hide/Show via menu validation.
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item(
            "Hide Sidebar", #selector(AppDelegate.menuToggleSidebar), target: target,
            key: "s", modifiers: [.command, .control]))
        main.addItem(submenuItem(viewMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        main.addItem(submenuItem(windowMenu))

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Velora on GitHub", #selector(AppDelegate.menuOpenGitHub), target: target))
        helpMenu.addItem(item("Report an Issue…", #selector(AppDelegate.menuReportIssue), target: target))
        main.addItem(submenuItem(helpMenu))

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        // The parent item needs its own title — assigning a submenu does not
        // copy it up, and the bar would read "NSMenuItem" (review finding,
        // AppKit-probed).
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector, target: AnyObject? = nil,
        key: String = "", modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }
}
