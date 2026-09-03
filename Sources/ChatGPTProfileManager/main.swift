import AppKit

NSWindow.allowsAutomaticWindowTabbing = false

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
