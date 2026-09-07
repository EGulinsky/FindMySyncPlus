import SwiftUI

/// The app's container vocabulary.
///
/// `ImageRenderer` cannot draw AppKit-backed containers. Measured — mean luminance of the
/// same content at 400×300:
///
/// | container | result |
/// |---|---|
/// | `VStack` | 0.202, draws correctly |
/// | `VSplitView` | 0.572, the yellow-and-red "cannot draw this" placeholder |
/// | `List` | 0.572, the same placeholder |
/// | `ScrollView` | 1.000, pure white — nothing drawn at all |
///
/// So a screen built from these renders as a placeholder or as nothing. These types use the
/// real container normally and a plain stack while a snapshot is being taken.
///
/// **They are the app's containers, not test scaffolding.** A container this app cannot
/// render is a real limitation of that container; owning a vocabulary that does render is
/// worth having whoever consumes it.
///
/// What the substitution costs: no divider, no scroll position, content at full height
/// rather than clipped to a viewport. What it preserves is which rows appear, what they say
/// and how they group — which is what a regression run reads.

/// The only place in the app that decides whether a render is in progress.
///
/// **Gated on the output directory as well as the in-flight flag.** If `isRendering` ever
/// stuck true, every `ScrollView` in a shipped build would become a `VStack` and nothing
/// would scroll. Requiring `demoRenderExport` to be set as well makes that unreachable for
/// anyone who has not opted in — an impossible bug rather than an unlikely one.
@MainActor @ViewBuilder
func substituting<Real: View, Fallback: View>(
    _ real: () -> Real,
    whileRendering fallback: () -> Fallback
) -> some View {
    if ViewSnapshotExport.isRendering, ViewSnapshotExport.outputDirectory != nil {
        fallback()
    } else {
        real()
    }
}

/// A vertical split. A plain stack while rendering.
struct AppVSplit<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        substituting({ VSplitView { content } },
                     whileRendering: { stack })
    }
    /// `.fixedSize` vertically is what makes a render fit its content.
    ///
    /// Without it the stack absorbs whatever height it is offered and hands each pane an
    /// equal share, so a short list becomes a tall empty card. Unbounded is worse:
    /// `SectionCard` paints its background through a `GeometryReader`, which has no intrinsic
    /// height, so it expands and paints over the pane below — the Aliases section header
    /// disappeared under it rather than being clipped, and nothing looked broken.
    private var stack: some View {
        VStack(spacing: 0) { content }.fixedSize(horizontal: false, vertical: true)
    }
}

/// A scrolling container. A plain stack while rendering.
///
/// **Takes no scroll parameters, and that is a decision rather than an omission.** A modifier
/// aimed at the container — `.scrollPosition`, `.contentMargins`, `.scrollTargetLayout` —
/// would land on this wrapper with the real `ScrollView` inside a `_ConditionalContent`, and
/// might silently stop binding.
///
/// `StatusView` is the only view that does this, and it does it three times with scroll
/// position persisted across launches. Forwarding three modifiers to serve one caller would
/// make this type worse, so **`StatusView` keeps its raw `ScrollView`** and is not covered.
/// The other four are plain `ScrollView { VStack { … } }` and migrate cleanly.
///
/// If `StatusView` is ever covered, add what it needs then, knowing what that is.
struct AppScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        substituting({ ScrollView { content } },
                     whileRendering: { VStack(spacing: 0) { content } })
    }
}

/// A menu picker. While rendering, a label naming the current selection.
///
/// A menu `Picker` is `NSPopUpButton`-backed and renders as the same placeholder. A constant
/// placeholder would never cause a false failure, but it hides which filter is applied, and a
/// render that cannot show the view's state is worth less to whoever reads it.
struct AppMenuPicker<Content: View>: View {
    let selectionTitle: String
    @ViewBuilder var content: Content
    var body: some View {
        substituting({ content }, whileRendering: { label })
    }
    private var label: some View {
        Text(selectionTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1))
    }
}
