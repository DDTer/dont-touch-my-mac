import SwiftUI

struct Poster: View {
    @ObservedObject var model: GuardModel
    var isWarning: Bool = false

    @State private var shockwaveProgress: CGFloat = 0.0
    @State private var pulseGlow = false
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height * 1.5)
            ZStack {
                switch model.posterTheme {
                case .classic:
                    ClassicPoster(model: model, w: w)
                case .cyber:
                    CyberPoster(model: model, w: w)
                case .anime:
                    AnimePoster(model: model, w: w)
                case .terminal:
                    TerminalPoster(model: model, w: w)
                }

                // Interactive Force Field Overlay
                ForceFieldOverlay(theme: model.posterTheme, w: w, pulse: pulseGlow, shockwave: shockwaveProgress)
            }
            .offset(x: shakeOffset, y: shakeOffset * 0.4)
            .onAppear {
                if isWarning {
                    withAnimation(.easeOut(duration: 0.9)) {
                        shockwaveProgress = 1.0
                    }
                    withAnimation(.easeInOut(duration: 0.05).repeatCount(5, autoreverses: true)) {
                        shakeOffset = 6
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shakeOffset = 0
                    }
                }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulseGlow = true
                }
            }
        }
    }
}

// MARK: - 1. Classic Theme (经典)
private struct ClassicPoster: View {
    @ObservedObject var model: GuardModel
    let w: CGFloat

    var body: some View {
        ZStack {
            lime
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.t("poster.kicker")).font(.system(size: w * 0.022, weight: .bold, design: .monospaced))
                    Spacer()
                    Image(systemName: "hand.raised.fill").font(.system(size: w * 0.033, weight: .bold))
                }
                Spacer(minLength: 10)
                HStack(alignment: .center, spacing: 0) {
                    Text(model.t("poster.title"))
                        .font(.system(size: w * (model.localizer.language == .en ? 0.125 : model.localizer.language == .zh ? 0.14 : 0.105), weight: .black, design: .rounded))
                        .tracking(-w * 0.006).lineSpacing(-w * 0.016)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: w * 0.64, alignment: .leading)
                    Spacer(minLength: 0)
                    Image(systemName: "hand.raised.slash.fill")
                        .font(.system(size: w * 0.23, weight: .black))
                        .rotationEffect(.degrees(-12))
                }
                Spacer(minLength: 10)
                HStack(alignment: .bottom) {
                    Text(model.t("poster.subtitle"))
                        .font(.system(size: w * 0.033, weight: .semibold))
                    Spacer()
                    Text(model.t("poster.thanks"))
                        .font(.system(size: w * 0.016, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(w * 0.055)
            .foregroundStyle(ink)
        }
    }
}

// MARK: - 2. Cyber Force Field Theme (高压力场)
private struct CyberPoster: View {
    @ObservedObject var model: GuardModel
    let w: CGFloat

    private let cyberCyan = Color(red: 0.0, green: 0.95, blue: 1.0)
    private let electricBlue = Color(red: 0.1, green: 0.45, blue: 1.0)

    var body: some View {
        ZStack {
            // Deep sci-fi slate gradient
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.04, blue: 0.09), Color(red: 0.04, green: 0.08, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Faint grid lines
            VStack(spacing: w * 0.06) {
                ForEach(0..<8, id: \.self) { _ in
                    Rectangle().fill(cyberCyan.opacity(0.04)).frame(height: 1)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(cyberCyan).frame(width: 6, height: 6)
                        Text(model.t("theme.cyber.kicker"))
                            .font(.system(size: w * 0.022, weight: .bold, design: .monospaced))
                            .foregroundStyle(cyberCyan)
                    }
                    Spacer()
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: w * 0.035, weight: .bold))
                        .foregroundStyle(cyberCyan)
                }

                Spacer(minLength: 10)

                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.t("theme.cyber.title"))
                            .font(.system(size: w * (model.localizer.language == .en ? 0.105 : 0.115), weight: .black, design: .rounded))
                            .tracking(-w * 0.005)
                            .lineSpacing(-w * 0.012)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(cyberCyan)
                            .shadow(color: cyberCyan.opacity(0.6), radius: 14)
                    }
                    .frame(maxWidth: w * 0.65, alignment: .leading)

                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .stroke(cyberCyan.opacity(0.25), lineWidth: 2)
                            .frame(width: w * 0.28, height: w * 0.28)
                        Circle()
                            .stroke(electricBlue.opacity(0.35), lineWidth: 4)
                            .frame(width: w * 0.22, height: w * 0.22)
                        Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                            .font(.system(size: w * 0.18, weight: .black))
                            .foregroundStyle(cyberCyan)
                            .shadow(color: cyberCyan.opacity(0.8), radius: 18)
                    }
                }

                Spacer(minLength: 10)

                HStack(alignment: .bottom) {
                    Text(model.t("theme.cyber.subtitle"))
                        .font(.system(size: w * 0.031, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text(model.t("theme.cyber.thanks"))
                        .font(.system(size: w * 0.016, weight: .bold, design: .monospaced))
                        .foregroundStyle(cyberCyan.opacity(0.85))
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(w * 0.055)
        }
    }
}

// MARK: - 3. Anime Manga Theme (二次元)
private struct AnimePoster: View {
    @ObservedObject var model: GuardModel
    let w: CGFloat

    private let mangaPink = Color(red: 1.0, green: 0.22, blue: 0.6)
    private let mangaPurple = Color(red: 0.12, green: 0.04, blue: 0.18)

    var body: some View {
        ZStack {
            mangaPurple

            // Manga diagonal comic speed lines
            GeometryReader { _ in
                Path { path in
                    for i in stride(from: -200, to: 800, by: 45) {
                        path.move(to: CGPoint(x: CGFloat(i), y: 0))
                        path.addLine(to: CGPoint(x: CGFloat(i + 150), y: 500))
                    }
                }
                .stroke(mangaPink.opacity(0.06), lineWidth: 1.5)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.t("theme.anime.kicker"))
                        .font(.system(size: w * 0.023, weight: .heavy))
                        .foregroundStyle(mangaPink)
                    Spacer()
                    Image(systemName: "flame.fill")
                        .font(.system(size: w * 0.035, weight: .bold))
                        .foregroundStyle(mangaPink)
                }

                Spacer(minLength: 8)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.t("theme.anime.title"))
                            .font(.system(size: w * (model.localizer.language == .en ? 0.095 : 0.105), weight: .black, design: .rounded))
                            .tracking(-w * 0.005)
                            .lineSpacing(-w * 0.012)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.white)
                            .shadow(color: mangaPink.opacity(0.8), radius: 16)
                    }
                    .frame(maxWidth: w * 0.65, alignment: .leading)

                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .fill(mangaPink.opacity(0.18))
                            .frame(width: w * 0.26, height: w * 0.26)
                        Image(systemName: "hand.raised.slash.fill")
                            .font(.system(size: w * 0.2, weight: .black))
                            .foregroundStyle(mangaPink)
                            .rotationEffect(.degrees(-8))
                            .shadow(color: mangaPink, radius: 12)
                    }
                }

                Spacer(minLength: 8)

                HStack(alignment: .bottom) {
                    Text(model.t("theme.anime.subtitle"))
                        .font(.system(size: w * 0.034, weight: .bold))
                        .foregroundStyle(mangaPink)
                    Spacer()
                    Text(model.t("theme.anime.thanks"))
                        .font(.system(size: w * 0.018, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(w * 0.055)
        }
    }
}

// MARK: - 4. Terminal Kernel Panic Theme (极客终端)
private struct TerminalPoster: View {
    @ObservedObject var model: GuardModel
    let w: CGFloat

    private let matrixGreen = Color(red: 0.2, green: 1.0, blue: 0.35)

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.04, blue: 0.02)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.t("theme.terminal.kicker"))
                        .font(.system(size: w * 0.021, weight: .medium, design: .monospaced))
                        .foregroundStyle(matrixGreen.opacity(0.85))
                    Spacer()
                    Image(systemName: "terminal.fill")
                        .font(.system(size: w * 0.03, weight: .bold))
                        .foregroundStyle(matrixGreen)
                }

                Spacer(minLength: 10)

                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.t("theme.terminal.title"))
                            .font(.system(size: w * 0.088, weight: .heavy, design: .monospaced))
                            .lineSpacing(-w * 0.008)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(matrixGreen)
                            .shadow(color: matrixGreen.opacity(0.5), radius: 10)
                    }
                    .frame(maxWidth: w * 0.7, alignment: .leading)

                    Spacer(minLength: 0)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: w * 0.2, weight: .bold))
                        .foregroundStyle(matrixGreen)
                        .shadow(color: matrixGreen.opacity(0.6), radius: 12)
                }

                Spacer(minLength: 10)

                HStack(alignment: .bottom) {
                    Text(model.t("theme.terminal.subtitle"))
                        .font(.system(size: w * 0.026, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text(model.t("theme.terminal.thanks"))
                        .font(.system(size: w * 0.016, weight: .bold, design: .monospaced))
                        .foregroundStyle(matrixGreen)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(w * 0.055)
        }
    }
}

// MARK: - Force Field Dynamic Overlay (科幻力场与电弧光效)
private struct ForceFieldOverlay: View {
    let theme: PosterTheme
    let w: CGFloat
    let pulse: Bool
    let shockwave: CGFloat

    private var accentColor: Color {
        switch theme {
        case .classic: return Color(red: 0.81, green: 0.98, blue: 0.28)
        case .cyber: return Color(red: 0.0, green: 0.95, blue: 1.0)
        case .anime: return Color(red: 1.0, green: 0.22, blue: 0.6)
        case .terminal: return Color(red: 0.2, green: 1.0, blue: 0.35)
        }
    }

    var body: some View {
        ZStack {
            // Perimeter energy border with breathing pulse
            RoundedRectangle(cornerRadius: 10)
                .stroke(accentColor.opacity(pulse ? 0.65 : 0.2), lineWidth: 2)
                .padding(3)

            // Sci-fi corner brackets
            GeometryReader { g in
                let len = min(g.size.width, g.size.height) * 0.07
                Path { p in
                    // Top-Left
                    p.move(to: CGPoint(x: 10, y: 10 + len))
                    p.addLine(to: CGPoint(x: 10, y: 10))
                    p.addLine(to: CGPoint(x: 10 + len, y: 10))

                    // Top-Right
                    p.move(to: CGPoint(x: g.size.width - 10 - len, y: 10))
                    p.addLine(to: CGPoint(x: g.size.width - 10, y: 10))
                    p.addLine(to: CGPoint(x: g.size.width - 10, y: 10 + len))

                    // Bottom-Left
                    p.move(to: CGPoint(x: 10, y: g.size.height - 10 - len))
                    p.addLine(to: CGPoint(x: 10, y: g.size.height - 10))
                    p.addLine(to: CGPoint(x: 10 + len, y: g.size.height - 10))

                    // Bottom-Right
                    p.move(to: CGPoint(x: g.size.width - 10 - len, y: g.size.height - 10))
                    p.addLine(to: CGPoint(x: g.size.width - 10, y: g.size.height - 10))
                    p.addLine(to: CGPoint(x: g.size.width - 10, y: g.size.height - 10 - len))
                }
                .stroke(accentColor.opacity(pulse ? 0.9 : 0.4), lineWidth: 2.5)
            }

            // Expanding shockwave ripple ring on warning trigger
            if shockwave > 0 && shockwave < 1.0 {
                Circle()
                    .stroke(accentColor.opacity(Double(1.0 - shockwave)), lineWidth: 3.5)
                    .scaleEffect(0.3 + shockwave * 1.8)
            }
        }
    }
}
