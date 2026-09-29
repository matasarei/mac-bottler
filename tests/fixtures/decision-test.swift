// Checks core/launcher/Decision.swift: when opening the app starts the game at once.
import Foundation
// Prints one line per failed case; exits 1 if any failed.
var failed = 0
func check(_ name: String, _ got: Bool, _ want: Bool) {
    if got != want { print("decision: \(name): expected \(want)"); failed += 1 }
}
func starts(installed: Bool = true, variants: Int = 1, displays: Int = 1, autorun: Bool = false,
            displayFound: Bool = true, option: Bool = false) -> Bool {
    startsDirectly(installed: installed, variants: variants, displays: displays, autorun: autorun,
                   rememberedDisplayConnected: displayFound, optionHeld: option)
}
check("nothing to choose", starts(), true)
check("nothing to choose, Option held", starts(option: true), false)
check("not installed", starts(installed: false), false)
check("two variants", starts(variants: 2), false)
check("two displays", starts(displays: 2), false)
check("two variants, autorun", starts(variants: 2, autorun: true), true)
check("two displays, autorun", starts(displays: 2, autorun: true), true)
check("autorun, Option held", starts(variants: 2, autorun: true, option: true), false)
check("autorun, remembered display gone", starts(displays: 2, autorun: true, displayFound: false), false)
check("autorun, not installed", starts(installed: false, variants: 2, autorun: true), false)
if failed > 0 { exit(1) }
print("decision: ok")
