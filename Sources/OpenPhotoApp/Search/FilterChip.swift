import SwiftUI
import OpenPhotoCore

enum ChipState { case included, excluded }

/// A negatable filter value: tap to flip include ⇆ exclude, ✕ to remove.
/// Included = accent fill; excluded = red outline + minus.
struct FilterChip: View {
    let label: String
    var symbol: String? = nil
    let state: ChipState
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state == .excluded ? "minus" : (symbol ?? "checkmark"))
                .font(.system(size: 9, weight: .bold))
            Text(label).font(.system(size: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(state == .excluded ? Theme.red : Theme.accent)
        .background(state == .excluded ? Theme.red.opacity(0.12) : Theme.accentDim,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(state == .excluded ? Theme.red.opacity(0.7) : Theme.accent.opacity(0.4),
                          lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(state == .excluded ? "Excluded — click to include" : "Included — click to exclude")
    }
}
