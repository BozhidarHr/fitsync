import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

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
                        Section("Last run (\(report.reason.rawValue))") {
                            LabeledContent("Written or updated", value: "\(report.written)")
                            LabeledContent("Workouts rebuilt", value: "\(report.workouts)")
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
                        Button("Re-request Apple Health access") { Task { await model.requestHealthAccess() } }
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                    } footer: {
                        Text("Turn off Apple Health sharing in the Google Health app for workouts, activity, heart rate and sleep, or Apple Health will show workouts twice.")
                    }
                }
            }
            .navigationTitle("FitSync")
            .refreshable { await model.syncNow() }
        }
    }
}
