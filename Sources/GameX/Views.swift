import SwiftUI
import GameXCore

enum Destination: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case boxes = "Boxes"
    case logs = "Logs"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge"
        case .boxes: return "shippingbox"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Destination = .dashboard

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.busy { ProgressView().controlSize(.small) }
                    if !model.message.isEmpty {
                        Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch selection {
                case .dashboard: DashboardView()
                case .boxes: BoxesView()
                case .logs: LogsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("System").font(.title2).bold()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    row("macOS", model.gpu.macOSVersion)
                    row("Architecture", model.gpu.architecture)
                    row("Chip", model.gpu.chip ?? "?")
                    row("GPU cores", model.gpu.gpuCores.map(String.init) ?? "?")
                    row("Metal", model.gpu.maxMetal)
                    if let rt = model.runtime {
                        row("Runtime", rt.summary)
                        row("D3DMetal", rt.hasD3DMetal ? "yes" : "no")
                        row("Steam-ready", rt.supportsModernSteam ? "yes" : "no (runtime too old)")
                    }
                }

                Divider()

                if let doctor = model.doctor {
                    HStack {
                        Text("Diagnostics").font(.title2).bold()
                        Spacer()
                        let c = doctor.counts
                        Text("\(c.ok) ok · \(c.warn) warn · \(c.fail) fail")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(doctor.checks.enumerated()), id: \.offset) { _, check in
                            CheckRow(check: check)
                        }
                    }
                }

                Divider()
                permissionsSection

                Divider()
                setupSection
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        HStack {
            Text("Permissions").font(.title2).bold()
            Spacer()
            Text("macOS · Privacy & Security").font(.caption).foregroundStyle(.secondary)
        }
        let ax = Permissions.accessibility()
        let im = Permissions.inputMonitoring()
        VStack(alignment: .leading, spacing: 6) {
            permissionRow("Accessibility (keyboard/mouse)", ax) { Permissions.openAccessibilitySettings() }
            permissionRow("Input Monitoring (controller)", im) { Permissions.openInputMonitoringSettings() }
            if let root = model.runtime?.runtimeRoot {
                Text("Add to both panels: \(root)/bin/wine — and GameX.app itself.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("Add the wine binary of the runtime — and GameX.app itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, _ access: Permissions.Access, _ open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: access.isGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(access.isGranted ? .green : .orange)
            Text(title)
            if access == .unknown { Text("(unknown)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Open Settings") { open() }.controlSize(.small)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        HStack {
            Text("Components").font(.title2).bold()
            Spacer()
            if !model.missingComponents.isEmpty {
                Button {
                    Task { await model.installMissing() }
                } label: {
                    Label("Install missing", systemImage: "arrow.down.circle")
                }
                .disabled(model.busy)
            }
        }
        if model.missingComponents.isEmpty {
            Label("Everything installed", systemImage: "checkmark.seal").foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.missingComponents) { c in
                    HStack(spacing: 8) {
                        Image(systemName: c.installable ? "arrow.down.circle" : "hand.raised")
                            .foregroundStyle(c.installable ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title)
                            Text(c.reason).font(.caption).foregroundStyle(.secondary)
                            if let url = c.manualURL {
                                Text(url).font(.caption2).foregroundStyle(.blue).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if c.installable {
                            Button("Install") { Task { await model.installComponent(c) } }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(model.busy)
                        } else {
                            Text("manual").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if !model.optionalComponents.isEmpty {
            Text("Optional (not required): " + model.optionalComponents.map { $0.title }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CheckRow: View {
    @EnvironmentObject var model: AppModel
    let check: Doctor.Check
    var color: Color {
        switch check.status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                if let detail = check.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let remedy = check.remedy {
                    Text("→ \(remedy)").font(.caption).foregroundStyle(.blue)
                }
                if let action = check.action {
                    actionButton(action).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Doctor.Action) -> some View {
        switch action {
        case .installComponent:
            if let id = check.componentID,
               let c = model.setupComponents.first(where: { $0.id == id }) {
                if c.installable {
                    Button("Install") { Task { await model.installComponent(id: id) } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(model.busy)
                } else if let urlString = c.manualURL, let url = URL(string: urlString) {
                    Link("Install…", destination: url).font(.caption)
                }
            }
        case .buildRuntime:
            Button("Build runtime") { Task { await model.buildRuntime() } }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.busy)
        case .openAccessibility:
            Button("Open Settings") { Permissions.openAccessibilitySettings() }
                .buttonStyle(.bordered).controlSize(.small)
        case .openInputMonitoring:
            Button("Open Settings") { Permissions.openInputMonitoringSettings() }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

// MARK: - Boxes

struct BoxesView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRemove: PrefixRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("New box name", text: $model.newPrefixName)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                Picker("", selection: $model.newPrefixRuntime) {
                    ForEach(model.runtimeChoices) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .labelsHidden().frame(maxWidth: 320)
                Button("Create") { Task { await model.createPrefix() } }
                    .disabled(model.newPrefixName.isEmpty || model.busy)
                Spacer()
                Button("Clean debugger") { model.cleanStaleDebuggers() }
                    .help("Kills stale winedbg processes left by previous crashes (prevents running out of system processes)")
                Button("Empty trash") { Task { await model.purgeTrash() } }
            }
            .padding(12)

            Text("The **default** runtime is **Wine+D3DMetal** (`wine-gptk`, Apple's path) — the only supported option. It is self-contained (Wine + renderer + dependencies inside the runtime).")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)

            if model.prefixes.isEmpty {
                Text("No boxes yet. Create one above (the default runtime is wine-gptk).")
                    .foregroundStyle(.secondary).padding(24)
                Spacer()
            } else {
                List {
                    ForEach(model.prefixes) { box in
                        BoxRow(box: box, confirmRemove: $confirmRemove)
                    }
                }
            }
        }
        .confirmationDialog("Remove this box?", isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { box in
            Button("Move to trash", role: .destructive) {
                Task { await model.removePrefix(box); confirmRemove = nil }
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: { box in
            Text("The box '\(box.name)' will be moved to the internal trash (recoverable). Saves are not deleted.")
        }
        .sheet(item: $model.runProgramBox) { box in
            RunProgramSheet(box: box)
        }
    }
}

struct BoxRow: View {
    @EnvironmentObject var model: AppModel
    let box: PrefixRecord
    @Binding var confirmRemove: PrefixRecord?

    var badge: AppModel.SteamBadge { model.badge(box) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(box.name).font(.headline)
                Text(model.runtimeLabel(box)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.prefixSize(box)).font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Run program…") { model.runProgramBox = box; model.runProgramCommand = ""; model.runProgramOutput = "" }
                    Button("Open in Finder") { model.openPrefix(box) }
                    Button("Remove (trash)", role: .destructive) { confirmRemove = box }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }

            if !badge.installed {
                if model.prefixSupportsSteam(box) {
                    HStack(spacing: 8) {
                        Button("Install Steam (online)") { Task { await model.installSteam(into: box) } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(model.busy)
                        Text("downloads Steam from Valve, applies the first update and the shim")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("This box's runtime is too old for the Steam UI. Recreate it with the wine-gptk runtime (Wine+D3DMetal).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: badge.shim ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(badge.shim ? .green : .red)
                        Text(badge.shim ? "shim ok" : "shim missing").font(.caption)
                    }
                    Spacer()
                    Button("Run") { model.runSteam(box) }.buttonStyle(.bordered).controlSize(.small)
                    Button("Stop") { model.stopSteam(box) }.buttonStyle(.bordered).controlSize(.small)
                    Button("Repair shim") { Task { await model.repairSteam(box) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Run Program

struct RunProgramSheet: View {
    @EnvironmentObject var model: AppModel
    let box: PrefixRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run program in '\(box.name)'").font(.headline)
            Text("Any Windows command: `notepad`, `cmd /c dir C:\\`, `C:\\Program Files\\App\\app.exe --flag`")
                .font(.caption).foregroundStyle(.secondary)
            TextField("command", text: $model.runProgramCommand)
                .textFieldStyle(.roundedBorder)
                .onSubmit { run() }
            HStack {
                Button("Run") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runProgramCommand.isEmpty || model.runProgramRunning)
                if model.runProgramRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { model.runProgramBox = nil }
            }
            ScrollView {
                Text(model.runProgramOutput.isEmpty ? "(output)" : model.runProgramOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minWidth: 520, minHeight: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(width: 580)
    }

    private func run() {
        let command = model.runProgramCommand
        guard !command.isEmpty else { return }
        Task { await model.runProgram(in: box, command: command) }
    }
}


struct LogsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            List(model.logs, id: \.self, selection: Binding(
                get: { model.selectedLog },
                set: { if let url = $0 { model.loadLog(url) } }
            )) { url in
                Text(url.lastPathComponent).lineLimit(1).help(url.path)
            }
            .frame(minWidth: 220, idealWidth: 260)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.selectedLog?.path ?? "Select a log").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { model.reloadSelectedLog() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.selectedLog == nil)
                }
                .padding(8)
                Divider()
                ScrollView {
                    Text(model.logText.isEmpty ? "(empty)" : model.logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
    }
}
