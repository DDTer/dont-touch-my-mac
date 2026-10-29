import SwiftUI

struct Poster: View {
    @ObservedObject var model: GuardModel

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height * 1.5)
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
}
