import SwiftUI

/// 0–5 star rating picker. Clicking the current star resets the rating to 0.
struct StarRatingPicker: View {
    let rating: Int
    var size: CGFloat = 16
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    onChange(i == rating ? 0 : i)
                } label: {
                    Image(systemName: i <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(i <= rating ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("\(i) étoile\(i > 1 ? "s" : "")")
            }
        }
    }
}

/// Small star badge shown on thumbnails.
struct StarBadge: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<rating, id: \.self) { _ in
                Image(systemName: "star.fill")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.yellow)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

/// Tag chip with a remove button.
struct TagChip: View {
    let name: String
    var systemImage: String?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(name)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Retirer l'étiquette")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

/// Layout that wraps items onto new lines (for tags).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Message shown at the bottom of the window after an operation; it does not block anything
/// and disappears by itself. `undo`: adds an "Annuler" button (move to the Trash).
struct NoticeToast: View {
    let text: String
    var undo: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            if let undo {
                Button("Annuler", action: undo)
                    .help("Remet les fichiers à leur place, avec leurs notes, personnes et albums")
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Fermer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
    }
}

/// Alias to the `State` property wrapper: with Command Line Tools only,
/// the SDK's `@State` macro has no plugin; the alias bypasses the macro.
typealias Etat = SwiftUI.State
