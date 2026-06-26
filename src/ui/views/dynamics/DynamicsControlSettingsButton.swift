import SwiftUI

/// A gear-icon button that presents a popover containing a single dynamics
/// control's full parameter set. Used to the right of every master toggle
/// in the Dynamics inline header widget (and, for ungated controls like
/// Stereo Matrix, next to a Column 4 picker instead of a toggle).
struct DynamicsControlSettingsButton<Content: View>: View {
    let fullName: String
    @ViewBuilder var content: () -> Content

    @State private var isPresented = false
    /// Dummy focus anchor — immediately captures automatic first-responder
    /// assignment so no real TextField inside the popover is auto-focused on open.
    /// Users can still click into any text field manually; only the automatic
    /// default-focus behaviour is suppressed.
    @FocusState private var popoverDefaultFocus: Bool?

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "gearshape")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("\(fullName) settings")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                // Invisible zero-size focusable element that claims default focus,
                // preventing the first real TextField from being auto-focused.
                Color.clear
                    .frame(width: 0, height: 0)
                    .focused($popoverDefaultFocus, equals: true)
                    .onAppear { popoverDefaultFocus = true }

                Text(fullName)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($popoverDefaultFocus, equals: true)
                Divider()
                content()
            }
            .padding(16)
            .frame(width: 400)
            // Force the popover to size to the content's actual layout pass rather
            // than relying on ambiguous intrinsic-size measurement, which can clip
            // the bottom of popovers containing bare Picker rows (Pause Gate,
            // Infrasonic Filter) that don't contribute a clear height anchor.
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
