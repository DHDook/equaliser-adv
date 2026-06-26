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
                Button("") { }
                    .buttonStyle(.plain)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .focused($popoverDefaultFocus, equals: true)
                    .accessibilityHidden(true)
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
            .focused($focusedFieldToken, equals: false)
            .onAppear {
                // Don't try to win a same-frame race against SwiftUI's own
                // default-focus assignment. Let it happen, then explicitly
                // un-focus everything one runloop tick later, after the
                // popover's content (including every DynamicsSliderRow's
                // own onAppear) has finished its first layout pass.
                DispatchQueue.main.async {
                    focusedFieldToken = false
                }
        }
    }
}
