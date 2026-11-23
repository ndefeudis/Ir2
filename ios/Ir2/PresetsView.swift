import Ir2Kit
import SwiftUI

/// Looks kept on the phone: one tap puts one on the car (as a preview; "Save to car" on Look keeps it).
struct PresetsView: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                ForEach(model.presets) { p in
                    Button {
                        model.apply(p)
                    } label: {
                        HStack(spacing: 14) {
                            Circle().fill(Color(rgb: p.color)).frame(width: 32, height: 32)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundStyle(.primary)
                                Text("#\(AmbientPalette.hex(p.color)) · brightness \(p.brightness)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { model.presets.remove(atOffsets: $0) }
                .onMove { model.presets.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Tap to preview on the car. Then Save to car on the Look tab keeps it.")
            }
            Section {
                ErrorBanner()
            }
        }
        .navigationTitle("Presets")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    name = ""
                    naming = true
                } label: {
                    Label("Save current look", systemImage: "plus")
                }
            }
        }
        .alert("Save the current look", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") {
                let n = name.trimmingCharacters(in: .whitespaces)
                model.presets.append(Preset(name: n.isEmpty ? "Look \(model.presets.count + 1)" : n,
                                            color: model.draftColor, brightness: model.draftBrightness))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("#\(AmbientPalette.hex(model.draftColor)), brightness \(model.draftBrightness)")
        }
    }
}
