import SwiftUI

struct TransferQueueView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Localization.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let queue = appModel.queue

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(l10n.t("queue.title"))
                    .font(.title2.weight(.semibold))

                Spacer()

                if queue.isPaused || queue.jobs.contains(where: { $0.state == .paused }) {
                    Button(l10n.t("queue.resume")) {
                        queue.resume()
                    }
                } else if queue.hasPendingJobs, !queue.isProcessing {
                    Button(l10n.t("queue.start")) {
                        queue.resume()
                    }
                } else if queue.isProcessing {
                    Button(l10n.t("queue.pause")) {
                        queue.pause()
                    }
                }

                if queue.isProcessing {
                    Button(l10n.t("queue.cancelCurrent")) {
                        queue.cancelCurrent()
                    }
                }

                Button(l10n.t("queue.clearCompleted")) {
                    queue.clearCompleted()
                }
            }
            .padding(16)

            Divider()

            if queue.jobs.isEmpty {
                ContentUnavailableView(
                    l10n.t("queue.empty"),
                    systemImage: "arrow.up.arrow.down"
                )
                Spacer()
            } else {
                List(queue.jobs) { job in
                    queueRow(job)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button(l10n.t("queue.done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 580, height: 460)
        .onExitCommand {
            dismiss()
        }
    }

    @ViewBuilder
    private func queueRow(_ job: TransferJob) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.direction == .download
                ? "arrow.down.circle"
                : "arrow.up.circle")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(l10n.t("queue.state.\(job.state.rawValue)"))
                    if job.state == .paused, job.errorMessage == "Interrupted" {
                        Text(l10n.t("queue.interrupted"))
                    } else if let error = job.errorMessage, !error.isEmpty {
                        Text(error).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let progress = job.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else if job.state == .running {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Spacer()

            if job.state == .running {
                Button(l10n.t("queue.cancelCurrent")) {
                    appModel.queue.cancelCurrent()
                }
                .controlSize(.small)
            } else if job.state == .failed || job.state == .paused || job.state == .canceled {
                Button(l10n.t("queue.retry")) {
                    appModel.queue.retry(job.id)
                }
                .controlSize(.small)
            }

            if job.state != .running {
                Button(l10n.t("queue.remove")) {
                    appModel.queue.remove(job.id)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
