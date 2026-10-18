import DroppyKit
import DroppyKitHarness
import SeaCoffeeDroplet

@main
struct SeaCoffeeHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { SeaCoffeeDroplet() }
}
