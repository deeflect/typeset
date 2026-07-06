import SwiftUI

/// YAML frontmatter rendered as a collapsed "Metadata · n fields" chip that
/// spring-expands into a neat key/value table. Keys are set in SF Mono.
struct FrontmatterView: View {
    let raw: String
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var fields: [(key: String, value: String)] { FrontmatterView.parse(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: theme.scaled(8)) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    Text("Metadata")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text("· \(fields.count) field\(fields.count == 1 ? "" : "s")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, theme.scaled(12))
                .padding(.vertical, theme.scaled(8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(theme.chipStroke)
                Grid(alignment: .topLeading, horizontalSpacing: theme.scaled(18), verticalSpacing: theme.scaled(7)) {
                    ForEach(fields, id: \.key) { field in
                        GridRow {
                            Text(field.key)
                                .font(.system(size: 12, weight: .medium, design: .monospaced).smallCaps())
                                .foregroundStyle(theme.textSecondary)
                                .textSelection(.enabled)
                            Text(field.value)
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, theme.scaled(14))
                .padding(.vertical, theme.scaled(11))
            }
        }
        .background(theme.chipFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.chipStroke, lineWidth: 1)
        )
        .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        .fixedSize(horizontal: !expanded, vertical: true)
        .padding(.bottom, theme.scaled(14))
    }

    static func parse(_ raw: String) -> [(key: String, value: String)] {
        var result: [(String, String)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed.isEmpty { continue }
            // Only treat top-level `key: value` lines (no leading indent) as fields.
            guard text.first != " ", text.first != "\t",
                  let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result.append((key, value.isEmpty ? "—" : value)) }
        }
        return result
    }
}
