import HealthKitUI
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    if model.isSignedIn {
                        Label("Connected to Google Health", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await model.signIn() }
                        } label: {
                            Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                } header: {
                    Text("Account")
                }

                if model.isSignedIn {
                    Section {
                        Button {
                            Task { await model.syncNow() }
                        } label: {
                            HStack {
                                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if model.isSyncing { ProgressView() }
                            }
                        }
                        .disabled(model.isSyncing)

                        if model.isSyncing, let progress = model.syncProgress {
                            Text(progress)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Last sync") {
                            if let date = model.lastSyncDate {
                                Text(date, format: .relative(presentation: .named))
                            } else {
                                Text("Never")
                            }
                        }
                        Stepper("Re-check last \(model.lookbackDays) days", value: $model.lookbackDays, in: 1...14)
                            .onChange(of: model.lookbackDays) { model.saveLookback() }
                    } header: {
                        Text("Sync")
                    } footer: {
                        Text("Syncing again is always safe: records already in Apple Health are skipped or replaced, never duplicated.")
                    }

                    if let report = model.lastReport {
                        Section("Last run") {
                            LabeledContent("Written or updated", value: "\(report.written)")
                            LabeledContent("Unchanged, skipped", value: "\(report.unchanged)")
                            LabeledContent("Removed", value: "\(report.deleted)")
                            ForEach(report.fetched.sorted(by: { $0.key < $1.key }), id: \.key) { type, count in
                                LabeledContent(type, value: "\(count) fetched")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let error = model.lastError {
                    Section("Problem") {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }

                if model.isSignedIn {
                    Section {
                        switch model.healthAccess {
                        case .notAsked:
                            Button("Grant Apple Health access") { model.requestHealthAccess() }
                        case .denied:
                            Text("Some Apple Health access is turned off. Allow all categories in Settings → Privacy & Security → Health → FitSync.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        case .full:
                            EmptyView()
                        }
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                    } footer: {
                        Text("In the Google Health app, keep Apple Health sharing on for workouts and heart rate, and turn it off for activity and sleep, or Apple Health will show them twice.")
                    }
                }
            }
            .navigationTitle("FitSync")
            .refreshable { await model.syncNow() }
            .healthDataAccessRequest(store: model.writer.store, shareTypes: model.writer.writeTypes,
                                     readTypes: model.writer.readTypes, trigger: model.healthAccessRequest) { [model = self.model] result in
                Task { await model.healthAccessRequestFinished(result) }
            }
            .task { await model.refreshHealthAccess() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refreshHealthAccess() } }
            }
        }
    }
}
