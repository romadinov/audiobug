import SwiftUI

/// The "Wi-Fi Upload" sheet: switch the server on or off, see the address to open, watch uploads arrive.
struct UploadServerView: View {
    @Environment(UploadServer.self) private var server
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var server = server
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { server.isRunning || server.isStarting }, set: { $0 ? server.start() : server.stop() })) {
                        HStack {
                            Label("Upload server", systemImage: "wifi")
                            if server.isStarting { ProgressView().padding(.leading, 4) }
                        }
                    }
                    .accessibilityIdentifier("upload.toggle")
                } footer: {
                    Text(server.isRunning
                         ? "Keep Audiobug open: iOS stops the server soon after the app leaves the screen (unless a book is playing). The screen stays on while it runs."
                         : "Starts a web page on the iPhone that computers and other devices on the same Wi-Fi network can open to add audiobooks.")
                }

                if server.isRunning {
                    Section {
                        if server.urls.isEmpty {
                            Label("The iPhone has no Wi-Fi address. Join a Wi-Fi network.", systemImage: "wifi.slash").foregroundStyle(.secondary)
                        }
                        ForEach(server.urls, id: \.self) { url in
                            HStack {
                                Text(url).font(.body.monospaced()).textSelection(.enabled)
                                    .accessibilityIdentifier("upload.url")
                                Spacer()
                                Button { UIPasteboard.general.string = url } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Copy address")
                            }
                        }
                    } header: {
                        Text("Open in a browser")
                    } footer: {
                        Text("On a Mac or PC on the same Wi-Fi, open the address and drop M4B, M4A or MP3 files on the page; choose a folder there if you like. From a terminal: curl -T Book.m4b \(server.urls.first ?? "http://…")/upload/Book.m4b")
                    }

                    if !server.uploads.isEmpty {
                        Section("Receiving") {
                            ForEach(server.uploads) { upload in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(upload.name).lineLimit(1)
                                        Spacer()
                                        Text("\(Int(upload.fraction * 100))%").foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    ProgressView(value: upload.fraction)
                                    if !upload.folder.isEmpty { Text(upload.folder).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }

                    if !server.imported.isEmpty {
                        Section("Added") {
                            ForEach(server.imported, id: \.self) { Label($0, systemImage: "checkmark.circle").lineLimit(1) }
                        }
                    }
                }
            }
            .navigationTitle("Wi-Fi Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Wi-Fi Upload", isPresented: Binding(get: { server.lastError != nil }, set: { if !$0 { server.lastError = nil } })) {
                Button("OK") {}
            } message: {
                Text(server.lastError ?? "")
            }
            .onAppear { if server.isRunning { server.refreshAddresses() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active, server.isRunning { server.refreshAddresses() } }
        }
    }
}

/// Shown at the top of the library while the server runs; tapping it opens the sheet.
struct UploadServerBanner: View {
    @Environment(UploadServer.self) private var server
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top) {
                Image(systemName: "wifi").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi upload is on").font(.subheadline.weight(.semibold))
                    Text(server.urls.first ?? "No Wi-Fi address").font(.caption.monospaced()).foregroundStyle(.secondary)
                    ForEach(server.uploads) { upload in
                        HStack {
                            Text(upload.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(Int(upload.fraction * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ProgressView(value: upload.fraction)
                    }
                    if let last = server.imported.first {
                        Text("Added \(last)\(server.imported.count > 1 ? " and \(server.imported.count - 1) more" : "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button("Stop") { server.stop() }.buttonStyle(.bordered).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("upload.banner")
    }
}
