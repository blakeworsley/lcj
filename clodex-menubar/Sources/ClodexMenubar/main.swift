/// main.swift — manual NSApplication bootstrap.
///
/// WHY not @main / -parse-as-library: SPM executableTarget with AppKit requires a
/// manual entrypoint when using NSApplication because @main creates a static main()
/// which conflicts with SPM's implicit top-level execution model. This approach is
/// well-established for SPM + AppKit apps (see SE-0281).

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Belt-and-suspenders with LSUIElement=true in Info.plist:
// setActivationPolicy must be called before app.run() to suppress the Dock icon.
app.setActivationPolicy(.accessory)
app.run()
