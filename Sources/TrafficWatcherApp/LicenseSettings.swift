#if os(macOS)
import AppCore
import Licensing
import SwiftUI

struct LicenseSettings: View {
    let license: LicenseManager
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: license.entitlement.isPro ? "checkmark.seal.fill" : "seal")
                        .font(.system(size: 28))
                        .foregroundStyle(license.entitlement.isPro ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(license.entitlement.isPro ? "Traffic Watcher Pro" : "Traffic Watcher Free").font(.headline)
                        Text(license.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if license.isWorking { ProgressView().controlSize(.small) }
                }
            }

            if let stored = license.license {
                Section("License") {
                    let owner = [stored.customerName, stored.customerEmail].compactMap { $0 }.joined(separator: " · ")
                    if !owner.isEmpty {
                        LabeledContent("Licensed to", value: owner)
                    }
                    LabeledContent("Key") { Text(stored.maskedKey).monospaced() }
                    LabeledContent("Purchased", value: stored.purchasedAt.formatted(date: .long, time: .omitted))
                    LabeledContent("Updates included until",
                                   value: license.policy.updatesCovered(until: stored.purchasedAt).formatted(date: .long, time: .omitted))
                    LabeledContent("Last checked", value: stored.lastValidatedAt.formatted(.relative(presentation: .named)))
                    HStack {
                        Button("Check Now") { Task { await license.refresh() } }
                        Spacer()
                        Button("Deactivate on This Mac", role: .destructive) { Task { await license.deactivate() } }
                    }
                    .disabled(license.isWorking)
                }
            } else {
                Section {
                    HStack {
                        TextField("License key", text: $key, prompt: Text("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"))
                            .monospaced()
                            .onSubmit(activate)
                        Button("Activate", action: activate)
                            .keyboardShortcut(.defaultAction)
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.isWorking)
                    }
                    if let url = license.configuration.purchaseURL {
                        Link("Buy Traffic Watcher Pro", destination: url)
                    }
                } header: {
                    Text("Activate Pro")
                } footer: {
                    Text("Your key is in the email from Lemon Squeezy. To move it to another Mac, deactivate it here first.")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = license.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Section {
                ForEach(ProFeature.allCases, id: \.self) { feature in
                    Label {
                        Text(feature == .unlimitedSessions
                             ? "\(feature.title) (Free keeps the last \(license.policy.freeSessionLimit))"
                             : feature.title)
                    } icon: {
                        Image(systemName: license.entitlement.allows(feature) ? "checkmark.circle.fill" : "lock")
                            .foregroundStyle(license.entitlement.allows(feature) ? Color.green : Color.secondary)
                    }
                }
            } header: {
                Text("Pro includes")
            } footer: {
                Text("A license is yours to keep. It covers every version released in the 12 months after purchase, and those versions keep working after that.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func activate() {
        let entered = key
        Task {
            await license.activate(key: entered)
            if license.license != nil { key = "" }
        }
    }
}
#endif
