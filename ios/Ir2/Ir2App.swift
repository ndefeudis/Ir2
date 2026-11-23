import Ir2Kit
import SwiftUI

@main
struct Ir2App: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.pairing == nil {
            NavigationStack { PairView() }
        } else {
            TabView {
                NavigationStack { LookView() }
                    .tabItem { Label("Look", systemImage: "paintpalette") }
                NavigationStack { PresetsView() }
                    .tabItem { Label("Presets", systemImage: "square.grid.2x2") }
                NavigationStack { CarSettingsView() }
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                NavigationStack { CarView() }
                    .tabItem { Label("Car", systemImage: "car") }
            }
            .task { await model.refresh() }
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

/// The last error, shown under a screen's content.
struct ErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let e = model.lastError {
            Label(e, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
