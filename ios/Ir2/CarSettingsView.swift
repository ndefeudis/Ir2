import Ir2Kit
import SwiftUI

/// The mod's settings, drawn from its settings.json the way the HMG-API app on the car draws them.
/// Nothing here is specific to Ir2 Companion's own keys: a new setting in the mod shows up by itself.
struct CarSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var edits: [String: SettingValue] = [:]
    @State private var saved = false

    var body: some View {
        Form {
            if let s = model.settings {
                ForEach(s.schema) { spec in
                    Section {
                        field(spec, current: edits[spec.key] ?? s.values[spec.key] ?? spec.default)
                        if let d = spec.description { Text(d).font(.footnote).foregroundStyle(.secondary) }
                        if let w = spec.warning { Text(w).font(.footnote).foregroundStyle(.orange) }
                        if let v = edits[spec.key], let problem = spec.problem(with: v) {
                            Text(problem).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    Button("Save on the car") {
                        Task {
                            if await model.saveSettings(edits) {
                                edits = [:]
                                saved = true
                            }
                        }
                    }
                    .disabled(edits.isEmpty || hasProblems(s) || model.busy)
                    if saved && edits.isEmpty { Label("Saved", systemImage: "checkmark").foregroundStyle(.green) }
                    ErrorBanner()
                }
            } else {
                ProgressView()
                ErrorBanner()
            }
        }
        .navigationTitle("Settings")
        .refreshable { await model.refresh() }
        .onChange(of: edits) { _, _ in saved = false }
    }

    func hasProblems(_ s: SettingsPayload) -> Bool {
        s.schema.contains { spec in edits[spec.key].map { spec.problem(with: $0) != nil } ?? false }
    }

    @ViewBuilder
    func field(_ spec: SettingSpec, current: SettingValue?) -> some View {
        let title = spec.title ?? spec.key
        switch spec.kind {
        case .toggle:
            Toggle(title, isOn: Binding(get: { current?.bool ?? false }, set: { edits[spec.key] = .bool($0) }))
        case .choice:
            Picker(title, selection: Binding(get: { current ?? .string("") }, set: { edits[spec.key] = $0 })) {
                ForEach(spec.options ?? [], id: \.self) { o in
                    Text(o.title ?? label(o.value)).tag(o.value)
                }
            }
        case .number:
            let n = current?.int ?? 0
            Stepper("\(title): \(n)", value: Binding(get: { n }, set: { edits[spec.key] = .int($0) }),
                    in: (spec.min ?? Int.min)...(spec.max ?? Int.max))
        case .text:
            LabeledContent(title) {
                TextField(spec.default?.string ?? "", text: Binding(get: { current?.string ?? "" }, set: { edits[spec.key] = .string($0) }))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    func label(_ v: SettingValue) -> String {
        switch v {
        case .bool(let b): return b ? "On" : "Off"
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }
}
