import SwiftUI

/// Continues the static launch screen (same color and logo, same size), gives the logo a
/// short pulse, then fades into the app.
struct SplashView: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            Image("LaunchLogo")
                .scaleEffect(pulsing ? 1.08 : 1)
                .animation(.easeInOut(duration: 0.35).repeatCount(2, autoreverses: true), value: pulsing)
        }
        // Centered on the full screen like the launch screen (UIImageRespectsSafeAreaInsets = false).
        .ignoresSafeArea()
        .task {
            // Wait for iOS to finish fading out the static launch screen, or the two logos overlap.
            try? await Task.sleep(for: .milliseconds(250))
            pulsing = true
        }
    }
}

#Preview {
    SplashView()
}
