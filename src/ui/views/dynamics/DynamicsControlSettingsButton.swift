import SwiftUI

/// A gear-icon button that presents a popover containing a single dynamics
/// control's full parameter set. Used to the right of every master toggle
/// in the Dynamics inline header widget (and, for ungated controls like
/// Stereo Matrix, next to a Column 4 picker instead of a toggle).
struct DynamicsControlSettingsButton<Content: View>: View {
    let fullName: String
    @ViewBuilder var content: () -> Content

    @State private var isPresented = false

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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(fullName)
                        .font(.system(size: 14, weight: .semibold))
                    Divider()
                    content()
                }
                .padding(16)
            }
            .frame(width: 360)
            .frame(maxHeight: 480)
        }
    }
}
