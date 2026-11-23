import Ir2Kit
import SwiftUI

struct PairView: View {
    @Environment(AppModel.self) private var model
    @State private var host = "192.168.0.1"
    @State private var code = ""
    @State private var deviceName = "iPhone"
    @State private var info: CarInfo?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Text("On the car, open **Ir2 Companion** from the app menu and tap **Pair a phone**. Keep this iPhone on the car's Wi-Fi: it is whenever wireless CarPlay is connected.")
                    .font(.callout)
            }

            Section("Car") {
                TextField("Address", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task {
                        checking = true
                        info = await model.checkCar(host: host)
                        checking = false
                    }
                } label: {
                    HStack {
                        Text("Find the car")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                if let info {
                    LabeledContent(info.name, value: info.pairingOpen ? "Showing a code" : "No code on screen")
                }
            }

            Section("Pairing code") {
                TextField("XXXX-XXXX-XXXX-XXXX", text: $code)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: code) { _, new in
                        let grouped = Ir2Crypto.groupCode(new)
                        if grouped != new { code = grouped }
                    }
                TextField("This phone's name on the car", text: $deviceName)
            }

            Section {
                Button {
                    Task { _ = await model.pair(host: host, code: code, deviceName: deviceName) }
                } label: {
                    HStack {
                        Text("Pair").bold()
                        if model.busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(!Ir2Crypto.isValidCode(code) || host.isEmpty || model.busy)
                ErrorBanner()
            }
        }
        .navigationTitle("Pair with your car")
    }
}
