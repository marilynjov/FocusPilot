import FocusPilotCore
import SwiftUI

/// Settings in the planning window (design 07): tabs over grouped forms.
/// Browsers and iPhone arrive with #17 and #22.
struct SettingsPage: View {
    enum Tab: String, CaseIterable {
        case blocking = "Blocking", allowed = "Allowed", observe = "Observe", day = "Day", general = "General"
    }

    let model: AppModel
    @State private var tab = Tab.blocking

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 12)
            Divider()
            Group {
                switch tab {
                case .blocking: BlockingSettings(model: model)
                case .allowed: AllowedSettings(model: model)
                case .observe: ObserveSettings(model: model)
                case .day: DaySettings(model: model)
                case .general: GeneralSettings(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadRules() }
    }
}

/// An error line under a settings table.
struct SettingsError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}
