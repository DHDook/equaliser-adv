import AppKit

@MainActor
protocol ActivationPolicyApplying {
    func apply(_ policy: NSApplication.ActivationPolicy)
}

@MainActor
struct NSApplicationActivationPolicyApplier: ActivationPolicyApplying {
    func apply(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }
}

@MainActor
final class WindowActivationController: ObservableObject {
    enum WindowRole: Hashable {
        case equaliser
        case settings
    }

    private let policyApplier: ActivationPolicyApplying
    private var visibleWindows: Set<WindowRole> = []
    private var currentPolicy: NSApplication.ActivationPolicy?

    init(policyApplier: ActivationPolicyApplying = NSApplicationActivationPolicyApplier()) {
        self.policyApplier = policyApplier
    }

    func launchAsMenuBarApp() {
        guard visibleWindows.isEmpty else { return }
        apply(.accessory)
    }

    func prepareToShowWindow() {
        apply(.regular)
    }

    func windowBecameVisible(_ role: WindowRole) {
        visibleWindows.insert(role)
        apply(.regular)
    }

    func windowBecameHidden(_ role: WindowRole) {
        visibleWindows.remove(role)

        if visibleWindows.isEmpty {
            apply(.accessory)
        }
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard currentPolicy != policy else { return }
        currentPolicy = policy
        policyApplier.apply(policy)
    }
}
