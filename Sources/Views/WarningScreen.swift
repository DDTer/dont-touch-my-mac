import SwiftUI

struct WarningScreen: View {
    @ObservedObject var model: GuardModel
    let preview: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image = model.customImage {
                Color.black
                Image(nsImage: image).resizable().scaledToFit().padding(.bottom, 52)
            } else {
                Poster(model: model, isWarning: true)
            }
            HStack(spacing: 8) {
                Circle().fill(lime).frame(width: 6, height: 6)
                Text(model.t(model.replaying ? "status.replay" : preview ? "guard.previewFooter" : "guard.retract"))
                Text("·").foregroundStyle(.gray)
                Button(model.t(preview ? "guard.escapeClose" : "guard.escapePause")) { model.dismissWarning() }
                    .buttonStyle(.plain).fontWeight(.semibold)
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.black.opacity(0.9), in: Capsule())
            .padding(.bottom, 20)
        }
        .ignoresSafeArea()
    }
}
