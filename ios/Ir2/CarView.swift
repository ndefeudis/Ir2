import Ir2Kit
import SwiftUI

struct CarView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        Form {
            if let p = model.pairing {
                Section("Paired car") {
                    LabeledContent("Name", value: p.carName)
                    LabeledContent("Address", value: "\(p.host):\(p.port)")
                    LabeledContent("This phone's id", value: String(p.deviceID.prefix(8)) + "…")
                }
            }
            if let st = model.status {
                Section("Now") {
                    LabeledContent("Gear", value: st.parked == true ? "P" : st.parked == false ? "Not P" : "Unknown")
                    LabeledContent("Only in Park", value: st.guard.onlyInPark ? "On" : "Off")
                    LabeledContent("Ambient light", value: st.ambient.holding ? "Set from the phone" : "The car's own")
                }
            }
            Section {
                Button("Refresh") { Task { await model.refresh() } }
                Button("Unpair this phone", role: .destructive) { confirming = true }
                ErrorBanner()
            } footer: {
                Text("Unpairing removes this phone from the car (if it can be reached) and from this iPhone. You can also remove phones on the car's Ir2 Companion screen.")
            }
        }
        .navigationTitle(model.carName)
        .confirmationDialog("Unpair from \(model.carName)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await model.unpair() } }
        }
    }
}
