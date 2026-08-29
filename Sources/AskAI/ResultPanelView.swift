import SwiftUI
import AskAICore

/// Contents of the floating result panel.
struct ResultPanelView: View {
    @ObservedObject var model: PanelModel

    /// Panel width is fixed; height follows the content up to a cap.
    static let width: CGFloat = 380
    static let maxContentHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Ask AI")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: model.dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Close (esc)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()

        case .loading(let selection):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.callout).foregroundStyle(.secondary)
            }
            selectionEcho(selection)

        case .success(_, let answer):
            ScrollView {
                Text(answer)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: Self.maxContentHeight)
            HStack {
                Spacer()
                Button(action: { model.copy(answer) }) {
                    Label(model.didCopy ? "Copied" : "Copy",
                          systemImage: model.didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

        case .failure(_, let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if retryable {
                    Button("Retry", action: model.retry)
                        .controlSize(.small)
                }
            }

        case .emptySelection:
            Text("No text selected.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Dimmed echo of what was selected, so it is obvious which text is being
    /// asked about when the panel appears over a dense page.
    private func selectionEcho(_ selection: String) -> some View {
        Text(selection)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
