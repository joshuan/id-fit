import SwiftUI

/// The picker for the format the whole document is cropped to — or for mixed,
/// where each page is framed on its own. It belongs in the window's toolbar
/// rather than beside the crop controls: the format is a property of the whole
/// document, not of the page being framed, and framing now happens in the same
/// window, so the toolbar stays within reach.
struct AspectRatioMenu: View {
    let store: DocumentStore
    @Binding var isEditingCustom: Bool

    var body: some View {
        Menu {
            ForEach(AspectRatioPreset.allCases) { preset in
                Button {
                    store.setAspectRatio(preset.aspectRatio)
                } label: {
                    if currentPreset == preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
            Divider()
            Button("Custom…") { isEditingCustom = true }
        } label: {
            Label(label, systemImage: "aspectratio")
        }
        .help("One crop format for every page, or mixed")
    }

    private var currentPreset: AspectRatioPreset? {
        AspectRatioPreset.matching(store.state.cropAspectRatio)
    }

    private var label: String {
        if let currentPreset { return currentPreset.title }
        guard let ratio = store.state.cropAspectRatio else { return AspectRatioPreset.mixed.title }
        return "Custom (\(formatted(ratio.width)) × \(formatted(ratio.height)))"
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

struct CustomRatioSheet: View {
    let current: AspectRatio?
    let onApply: (AspectRatio) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var width: Double
    @State private var height: Double

    init(current: AspectRatio?, onApply: @escaping (AspectRatio) -> Void) {
        self.current = current
        self.onApply = onApply
        _width = State(initialValue: current?.width ?? 210)
        _height = State(initialValue: current?.height ?? 297)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Aspect Ratio")
                .font(.headline)
            HStack {
                TextField("Width", value: $width, format: .number)
                    .frame(width: 90)
                Text("×")
                TextField("Height", value: $height, format: .number)
                    .frame(width: 90)
            }
            .textFieldStyle(.roundedBorder)
            Text("Only the proportion matters, not the units.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    onApply(AspectRatio(width: width, height: height))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width <= 0 || height <= 0)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
