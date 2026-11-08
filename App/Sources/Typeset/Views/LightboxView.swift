import AppKit
import TypesetRendering
import SwiftUI

/// A Quick Look-style full-window image lightbox (PLAN §6). Presented over the
/// whole window by `DocumentWindow` when a reading-view image is clicked: a
/// dimmed scrim, the image fit to the window, pinch/scroll to zoom, and
/// click-anywhere or Esc to dismiss. Motion honors Reduce Motion.
struct LightboxView: View {
    let image: NSImage
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom: CGFloat = 1
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.86))
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .padding(40)
                .scaleEffect(appeared ? 1 : 0.96) // R06: image scales 0.96 → 1 with the fade
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom = clamp($0.magnification) }
                        .onEnded { _ in if zoom < 1.02 { withAnimation(.easeOut(duration: 0.2)) { zoom = 1 } } }
                )
                // Double-tap toggles zoom; dismissal is the scrim tap, the
                // close button, or Esc — so the image tap never fights the
                // zoom gesture with a disambiguation delay.
                .onTapGesture(count: 2) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        zoom = zoom > 1.01 ? 1 : 2
                    }
                }
                .accessibilityLabel("Zoomed image. Press Escape to close.")

            VStack {
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                }
                Spacer()
            }
            .padding(16)
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(Theme.Motion.state) { appeared = true }
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 1), 6) }

    private func dismiss() {
        guard reduceMotion == false else { onDismiss(); return }
        withAnimation(Theme.Motion.stateExit) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.exitDuration) { onDismiss() }
    }
}
