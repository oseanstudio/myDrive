import AppKit

@MainActor enum NativeFilePicker {
    static func makeApplicationMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu(title: "myDrive")
        app.addItem(withTitle: "Quit myDrive", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = app
        menu.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)
        return menu
    }
}

@MainActor extension NSSavePanel {
    func runMyDrivePicker() -> NSApplication.ModalResponse {
        // Accessory apps need to take focus when a picker is opened from the menu bar.
        // Leave the panel's own shortcuts, including Go to Folder, with AppKit.
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}
