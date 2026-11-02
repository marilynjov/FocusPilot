import FocusPilotCore
import SwiftUI

/// During a strict session, weakening a rule asks first, then counts down
/// `StrictEarlyEnd.wait` before it can be applied (decision 0003,
/// 2026-10-17), like ending the session early. Blocking stays on meanwhile.
/// An unapplied change disappears `StrictEarlyEnd.applyWindow` after it.
struct StrictRuleEditBanner: View {
    let model: AppModel

    var body: some View {
        if let pending = model.snapshot.pendingRuleEdit, model.now < pending.expiresAt {
            banner(RuleText.title(pending.edit, rules: model.ruleSets),
                   detail: RuleText.applyCountdown(availableAt: pending.availableAt, now: model.now)) {
                Button("Keep Rule") { Task { await model.cancelRuleEdit() } }
                Button("Apply Change") { Task { await model.perform(pending.edit, confirmed: false) } }
                    .accentProminentButton()
                    .disabled(model.now < pending.availableAt)
            }
        } else if let edit = model.ruleEditToConfirm {
            banner(RuleText.title(edit, rules: model.ruleSets),
                   detail: "This is a strict session, so weakening a rule waits \(StrictEarlyEnd.waitText) after you confirm. Blocking stays on until then.") {
                Button("Keep Rule") { model.ruleEditToConfirm = nil }
                Button("Continue") { Task { await model.perform(edit, confirmed: true) } }
            }
        }
    }

    private func banner(_ title: String, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            actions()
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}
