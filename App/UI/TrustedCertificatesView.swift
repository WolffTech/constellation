// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import SwiftUI

/// Settings › Certificates: every server whose certificate the user chose to
/// Always Trust, with a way to revoke that decision so the next connection
/// prompts again.
struct TrustedCertificatesView: View {
    let model: TrustedCertificatesModel
    @State private var selection: Set<TrustedCertificate.ID> = []

    var body: some View {
        Form {
            Section {
                if model.certificates.isEmpty {
                    ContentUnavailableView(
                        "No Trusted Certificates",
                        systemImage: "checkmark.shield",
                        description: Text("A server appears here after you choose Always Trust on its certificate prompt."))
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    Table(model.certificates, selection: $selection) {
                        TableColumn("Server") { certificate in
                            Text("\(certificate.host):\(String(certificate.port))")
                        }
                        TableColumn("Issued To") { certificate in
                            Text(certificate.commonName.isEmpty ? certificate.subject : certificate.commonName)
                        }
                        TableColumn("Issuer") { certificate in
                            Text(certificate.issuer)
                        }
                        TableColumn("Trusted") { certificate in
                            Text(certificate.trustedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                        }
                        .width(min: 80, ideal: 100)
                        TableColumn("SHA-256") { certificate in
                            Text(certificate.fingerprint)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .help(certificate.fingerprint)
                        }
                    }
                    .frame(minHeight: 240)
                    .onDeleteCommand(perform: forgetSelection)
                }
            } footer: {
                Text("Servers whose certificate you chose to Always Trust. Remove one to be asked again on the next connection.")
            }
            if !model.certificates.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        Button("Remove", role: .destructive, action: forgetSelection)
                            .disabled(selection.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .alert("Trusted certificates could not be updated", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.presentedError ?? "")
            }
    }

    private func forgetSelection() {
        let ids = selection
        selection = []
        Task { await model.forget(ids) }
    }
}
