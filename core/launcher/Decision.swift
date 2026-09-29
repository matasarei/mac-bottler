// When opening the app starts the game at once, with no launcher window. Kept apart
// from Launcher.swift so a native test can check it (tests/fixtures/decision-test.swift).

/// True when there is nothing to choose (one variant, one display), or when the
/// player asked for autorun and the display they chose is still connected. Holding
/// Option while opening the app always shows the window, and a game that is not
/// installed never starts.
func startsDirectly(installed: Bool, variants: Int, displays: Int, autorun: Bool,
                    rememberedDisplayConnected: Bool, optionHeld: Bool) -> Bool {
    guard installed && !optionHeld else { return false }
    if variants == 1 && displays == 1 { return true }
    return autorun && rememberedDisplayConnected
}
