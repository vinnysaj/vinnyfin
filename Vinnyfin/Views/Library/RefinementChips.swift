import SwiftUI

/// A list's order and filters as a row of chips under its title: the sort first, which a tap turns
/// the other way or, shuffled, shuffles again; then a chip for each filter, which a tap takes
/// away; then Clear, which takes them all away.
struct RefinementChips: View {
    @Binding var refinements: LibraryRefinements
    /// The server's libraries, which name a library's chip.
    let libraries: [JellyfinItem]
    let reshuffle: () -> Void

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 16) { content }
        #else
        ScrollView(.horizontal) {
            HStack(spacing: 8) { content }
        }
        .scrollIndicators(.hidden)
        // Chips scroll out past the page's margins rather than being cut off at them.
        .scrollClipDisabled()
        #endif
    }

    @ViewBuilder private var content: some View {
        if let sort = refinements.sort {
            sortChip(sort)
        }
        let chips = refinements.chips(libraries: libraries)
        ForEach(chips) { chip in
            Button {
                withAnimation { refinements.remove(chip) }
            } label: {
                HStack(spacing: 6) {
                    Text(chip.label)
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .modifier(ChipStyle())
            .accessibilityLabel("\(chip.label) filter")
            .accessibilityHint("Removes it")
            .accessibilityIdentifier("library.chip.\(chip.label)")
        }
        if !chips.isEmpty {
            Button("Clear") {
                withAnimation { refinements.clearFilters() }
            }
            .modifier(ChipStyle())
            .accessibilityHint("Removes every filter")
            .accessibilityIdentifier("library.clearChips")
        }
    }

    private func sortChip(_ sort: LibraryGridView.Sort) -> some View {
        Button {
            if sort == .random {
                reshuffle()
            } else {
                refinements.ascending.toggle()
            }
        } label: {
            Label {
                Text(refinements.sortSummary ?? sort.label)
            } icon: {
                Image(systemName: sort == .random ? "shuffle" : refinements.ascending ? "arrow.up" : "arrow.down")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .modifier(ChipStyle())
        .accessibilityLabel(sort == .random ? "Shuffled" : "Sorted by \(refinements.sortSummary ?? sort.label)")
        .accessibilityHint(sort == .random ? "Shuffles again" : "Reverses the order")
        .accessibilityIdentifier("library.sortChip")
    }
}

/// A small glass capsule, one of a row of chips.
private struct ChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            .buttonStyle(.platformGlass)
            #if !os(tvOS)
            .controlSize(.small)
            #endif
    }
}
