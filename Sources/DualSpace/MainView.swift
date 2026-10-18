// Native library and instance cards expose actions and observed compatibility separately.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DualSpaceCore

private let ink = Color(red: 0.055, green: 0.066, blue: 0.085)
private let panel = Color(red: 0.085, green: 0.10, blue: 0.125)
private let accent = Color(red: 0.49, green: 0.80, blue: 0.70)

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var dropping = false
    @State private var showActivity = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                header
                if let notice = model.notice { noticeView(notice) }
                if let working = model.working {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(working).font(.system(size: 12, weight: .medium))
                        Spacer()
                    }.padding(14).background(accent.opacity(0.08)).padding(.horizontal, 28).padding(.bottom, 14)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if model.section == "instances" { instances } else { library }
                    }.padding(.horizontal, 28).padding(.bottom, 28)
                }
                footer
            }.background(ink)
        }
        .tint(accent)
        .background(ink)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18).fill(accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [8])))
                    .overlay(Label("Drop an app to create an instance", systemImage: "plus.square.on.square").font(.title2).padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            guard let item = providers.first, model.working == nil else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.select(url) } }
            }
            return true
        }
        .sheet(item: $model.draft) { app in CreateView(model: model, app: app) }
        .sheet(item: $model.renameRequest) { request in RenameView(model: model, record: request.record) }
        .confirmationDialog("Remove this instance?", isPresented: Binding(get: { model.removeRequest != nil }, set: { if !$0 { model.removeRequest = nil } }), titleVisibility: .visible) {
            if let record = model.removeRequest {
                Button("Remove Copy, Keep Profile") { Task { await model.act(.remove, on: record) } }
                Button("Cancel", role: .cancel) { model.removeRequest = nil }
            }
        } message: { Text("Your profile is kept. A recoverable app copy is stored in the workspace's Retired folder.") }
        .sheet(isPresented: $showActivity) {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Session activity").font(.title2.bold()); Spacer(); Button("Done") { showActivity = false } }
                ScrollView { Text(model.activity.isEmpty ? "No activity yet." : model.activity.joined(separator: "\n\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(26).frame(width: 680, height: 400)
        }
        .task { await model.reload() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "square.on.square").font(.system(size: 26, weight: .semibold)).foregroundStyle(accent)
                if !model.sidebarCollapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DualSpace").font(.system(size: 19, weight: .semibold))
                        Text("MAKE ROOM FOR MORE").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 43).padding(.bottom, 40).padding(.horizontal, model.sidebarCollapsed ? 20 : 22)
            if !model.sidebarCollapsed {
                Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            }
            nav("My instances", icon: "square.stack.3d.up", key: "instances", count: model.instances.count)
            nav("App library", icon: "square.grid.2x2", key: "library", count: model.applications.count)
            Spacer()
            if model.sidebarCollapsed {
                VStack(spacing: 7) {
                    Circle().fill(model.pids.isEmpty ? .gray : accent).frame(width: 6, height: 6)
                    Text("\(model.pids.count)").font(.system(size: 12, weight: .medium, design: .monospaced))
                }.frame(maxWidth: .infinity).padding(.bottom, 22)
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(model.pids.count) running")
                    .help("\(model.pids.count) running")
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 7) { Circle().fill(model.pids.isEmpty ? .gray : accent).frame(width: 5, height: 5); Text("\(model.pids.count) running").font(.system(size: 11)) }
                    Text("Create once. Run on its own.\nNo manager required.").font(.system(size: 11)).lineSpacing(4).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(16)
            }
            Button { model.reveal(model.store.root) } label: {
                if model.sidebarCollapsed { Image(systemName: "folder").frame(maxWidth: .infinity) }
                else { Label("Open workspace", systemImage: "folder").font(.system(size: 11)) }
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 22)
                .accessibilityLabel("Open workspace").help("Open workspace")
        }.frame(width: model.sidebarCollapsed ? 68 : 216).background(Color(red: 0.038, green: 0.047, blue: 0.061))
    }

    private func nav(_ title: String, icon: String, key: String, count: Int) -> some View {
        Button { model.section = key; model.search = "" } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 19)
                if !model.sidebarCollapsed {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.foregroundStyle(model.section == key ? accent : Color.secondary).padding(.horizontal, 13).padding(.vertical, 12)
                .background(model.section == key ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 5)
            .accessibilityLabel("\(title), \(count)").help(title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.sidebarCollapsed.toggle() }
                } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 16)).padding(7)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(model.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
                    .help((model.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar") + " (⌃⌘S)")
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.section == "instances" ? "Your apps, in parallel." : "Pick an app. Make it yours.")
                        .font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                    Text(model.section == "instances" ? "Independent copies, one place to manage them." : "Create another space for work, personal, or something new.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Button { model.chooseApp() } label: { Label("New instance", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).foregroundStyle(ink).disabled(model.working != nil)
            }
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.section == "instances" ? "Find an instance…" : "Search installed apps…", text: $model.search).textFieldStyle(.plain)
                        .accessibilityLabel("Search")
                    if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.font(.system(size: 12)).padding(11).background(panel, in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 340)
                Spacer()
                Text(model.section == "instances" ? "\(model.filteredInstances.count) INSTANCES" : "\(model.filteredApps.count) APPLICATIONS")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.6).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 28).padding(.top, 47).padding(.bottom, 25)
    }

    @ViewBuilder private var instances: some View {
        if model.loadingInstances {
            ProgressView("Checking instances…").frame(maxWidth: .infinity).padding(.vertical, 70)
        } else if model.instances.isEmpty {
            VStack(spacing: 17) {
                Image(systemName: "square.on.square.dashed").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(accent)
                Text("A second space starts here.").font(.system(size: 21, weight: .medium))
                Text("Choose an app or drop its .app file here.\nGive the copy a name, then sign in separately.").font(.system(size: 12)).multilineTextAlignment(.center).lineSpacing(6).foregroundStyle(.secondary)
                Button("Choose an app…") { model.chooseApp() }.buttonStyle(.borderedProminent).foregroundStyle(ink).disabled(model.working != nil)
                Button("Browse app library") { model.section = "library" }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
            }.frame(maxWidth: .infinity).padding(.vertical, 70).background(panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        } else if model.filteredInstances.isEmpty {
            Text("No instances match your search.").foregroundStyle(.secondary).padding(.vertical, 40)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                ForEach(model.filteredInstances) { record in InstanceCard(model: model, record: record) }
            }
        }
        if !model.instances.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(accent.opacity(0.7))
                Text("A running copy confirms startup. Verify the account inside each app; some apps need additional compatibility support.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var library: some View {
        VStack(alignment: .leading) {
            if model.loadingLibrary { ProgressView("Loading app library…").padding(.vertical, 20) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                ForEach(model.filteredApps) { app in
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 12) {
                            AppIcon(path: app.path, size: 44)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(app.version).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Text(app.kind.label).font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button { model.select(URL(fileURLWithPath: app.path)) } label: { Label("Create copy", systemImage: "plus").font(.system(size: 11, weight: .medium)) }
                                .buttonStyle(.bordered).disabled(model.working != nil)
                        }
                    }.padding(19).background(panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.05)))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("LOCAL BY DESIGN").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.5)
            Spacer()
            Button { showActivity = true } label: { Label("Activity", systemImage: "list.bullet.rectangle").font(.system(size: 10)) }.buttonStyle(.plain)
        }.foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 15).overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }

    private func noticeView(_ notice: Notice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(notice.isError ? .orange : accent)
            Text(notice.text).font(.system(size: 11)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss message")
        }.padding(13).background(notice.isError ? Color.orange.opacity(0.08) : accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 28).padding(.bottom, 16)
    }
}

struct AppIcon: View {
    let path: String
    let size: CGFloat
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary.opacity(0.3)) }
        }.frame(width: size, height: size)
            .task(id: path) {
                let data = await Task.detached(priority: .utility) { NSWorkspace.shared.icon(forFile: path).tiffRepresentation }.value
                if let data { icon = NSImage(data: data) }
            }
    }
}

struct InstanceCard: View {
    @ObservedObject var model: AppModel
    let record: CloneRecord
    @State private var details = false
    private var state: InstanceState { model.state(for: record) }
    private var statusColor: Color {
        if state.error != nil || state.phase == .missing { return .orange }
        return state.phase == .running || state.phase.isBusy ? accent : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                AppIcon(path: model.store.appURL(record).path, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text(record.source.name + " · " + record.source.version).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Open Original App") { model.openOriginal(record) }
                    Button("Show Copy in Finder") { model.reveal(model.store.appURL(record)) }
                    Button("Show Profile Folder") { model.reveal(model.store.homeURL(record)) }
                    Divider()
                    Button("Rebuild from Original") { Task { await model.act(.refresh, on: record) } }.disabled(model.pids[record.id] != nil)
                    Button("Rename…") { model.renameRequest = RenameRequest(record: record) }.disabled(model.pids[record.id] != nil)
                    Button("Verify Copy") { Task { await model.act(.verify, on: record) } }
                    Button("Compatibility Details…") { details = true }
                    Divider()
                    Button("Remove Copy…") { model.removeRequest = record }.disabled(model.pids[record.id] != nil)
                } label: { Image(systemName: "ellipsis").font(.system(size: 14)) }.menuStyle(.borderlessButton).frame(width: 22).disabled(model.working != nil)
                    .accessibilityLabel("Actions for \(record.name)")
            }
            HStack(spacing: 6) {
                if state.phase.isBusy { ProgressView().controlSize(.mini) }
                else { Circle().fill(statusColor).frame(width: 6, height: 6) }
                Text(state.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(statusColor)
                Spacer()
                if model.outdated.contains(record.id) { Label("Update available", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundStyle(.orange) }
            }
            if let error = state.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.isolation).font(.system(size: 10, weight: .medium))
                    Text("Account separation: verify in app").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.pids[record.id] != nil {
                    Button("Quit") { Task { await model.act(.quit, on: record) } }.buttonStyle(.bordered).controlSize(.small)
                }
                Button(state.phase == .failed ? "Retry" : (state.pid != nil ? "Show" : "Open")) { Task { await model.act(.launch, on: record) } }
                    .buttonStyle(.borderedProminent).foregroundStyle(ink).controlSize(.small)
                    .disabled(state.pid == nil && model.missing.contains(record.id))
            }.disabled(model.working != nil || state.phase.isBusy)
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.06)))
        .sheet(isPresented: $details) {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(record.name).font(.title2.bold()); Spacer(); Button("Done") { details = false } }
                Text(record.isolation).font(.headline)
                ForEach(record.notes, id: \.self) { note in Label { Text(note).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) } }
                Divider()
                Text("Bundle ID: \(record.bundleID)\nData: \(model.store.homeURL(record).path)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }.padding(28).frame(width: 600)
        }
    }
}

struct CreateView: View {
    @ObservedObject var model: AppModel
    let app: AppDescriptor
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                AppIcon(path: app.path, size: 58)
                VStack(alignment: .leading, spacing: 6) {
                    Text("A new space for \(app.name)").font(.system(size: 21, weight: .semibold))
                    Text(app.kind.label + " · " + app.version).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("INSTANCE NAME").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                TextField("For example, WeChat Work", text: $model.draftName).textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel("Instance name")
            }
            Text("A separate app copy will be created. Open it and sign in with the account you want to use.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            DisclosureGroup("Compatibility details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    if let inspection = model.inspection {
                        ForEach(inspection.notes, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    } else if model.inspectionError == nil { ProgressView().controlSize(.small) }
                }.padding(.top, 12)
            }.font(.system(size: 11))
            if let notice = model.notice, notice.isError { Text(notice.text).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            if let working = model.working { HStack { ProgressView().controlSize(.small); Text(working).font(.system(size: 11)) } }
            HStack {
                Text("The original app stays yours.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.working != nil)
                Button("Create instance") { Task { await model.create() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.working != nil || model.inspection == nil || model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(30).frame(width: 540).interactiveDismissDisabled(model.working != nil)
    }
}

struct RenameView: View {
    @ObservedObject var model: AppModel
    let record: CloneRecord
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, record: CloneRecord) { self.model = model; self.record = record; _name = State(initialValue: record.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename instance").font(.title2.bold())
            TextField("Instance name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("New instance name")
            Text("The app copy will be rebuilt with its new name. Its identity and profile are kept.").font(.system(size: 12)).foregroundStyle(.secondary)
            if let notice = model.notice, notice.isError { Text(notice.text).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                if model.working != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(model.working != nil)
                Button("Rename") { Task { await model.rename(record, to: name) } }.buttonStyle(.borderedProminent).disabled(model.working != nil).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 460).interactiveDismissDisabled(model.working != nil)
    }
}
