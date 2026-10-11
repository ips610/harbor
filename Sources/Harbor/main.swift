import AppKit

// Debug/test commands (`--dump`, `--bench`, `--test-stop`, `--make-icon`) run
// without any UI and exit. Everything else starts the menu bar app.
if DebugCLI.handle(CommandLine.arguments) {
    exit(0)
}
HarborApp.main()
