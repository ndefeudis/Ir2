import Ir2Kit
import SwiftUI

/// The ambient light: the car's own 64 colours, brightness, live preview.
struct LookView: View {
    @Environment(AppModel.self) private var model
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusRow()

                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(rgb: model.draftColor).opacity(model.draftBrightness == 0 ? 0.15 : 0.35 + 0.065 * Double(model.draftBrightness)))
                    .frame(height: 72)
                    .overlay(
                        Text(model.draftBrightness == 0 ? "Off" : "#\(AmbientPalette.hex(model.draftColor))")
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    )
                    .accessibilityLabel("Chosen colour")

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(AmbientPalette.colors, id: \.self) { c in
                        Circle()
                            .fill(Color(rgb: c))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Circle().stroke(Color.primary, lineWidth: c == model.draftColor ? 3 : 0).padding(-3))
                            .onTapGesture {
                                model.draftColor = c
                                model.lookChanged()
                            }
                            .accessibilityLabel("Colour \(AmbientPalette.hex(c))")
                    }
                }

                VStack(alignment: .leading) {
                    Text("Brightness: \(model.draftBrightness == 0 ? "off" : String(model.draftBrightness))")
                        .font(.subheadline)
                    Slider(value: Binding(get: { Double(model.draftBrightness) },
                                          set: { model.draftBrightness = Int($0.rounded()) }),
                           in: 0...10, step: 1,
                           onEditingChanged: { editing in
                               if !editing { model.lookChanged() }
                           })
                }

                Toggle("Live preview on the car", isOn: $model.livePreview)

                HStack {
                    Button {
                        Task { await model.saveLook() }
                    } label: {
                        Label("Save to car", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await model.release() }
                    } label: {
                        Label("Car's own", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(model.busy)

                if let r = model.lastResult, r.nearest, let c = r.color {
                    Text("The car shows its nearest colour, #\(c).").font(.footnote).foregroundStyle(.secondary)
                }
                Text("The car shows these only with **Custom colour** chosen in its mood-lamp settings. \"Save to car\" keeps this look in the mod; turn on \"Ambient light from the phone at start\" in Settings to have it back at every start. \"Car's own\" gives the light back to the car's menu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ErrorBanner()
            }
            .padding()
        }
        .navigationTitle("Look")
        .refreshable { await model.refresh() }
    }
}

struct StatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let st = model.status {
                switch st.parked {
                case .some(true): Label("In P", systemImage: "parkingsign.circle.fill").foregroundStyle(.green)
                case .some(false): Label("Not in P", systemImage: "car.side.fill").foregroundStyle(st.guard.onlyInPark ? .orange : .secondary)
                case .none: Label("Gear unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Label(st.ambient.holding ? "Phone's light" : "Car's light", systemImage: "lightbulb.fill")
                    .foregroundStyle(st.ambient.holding ? Color.accentColor : .secondary)
            } else {
                ProgressView()
                Text("Reaching \(model.carName)…").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }
}
