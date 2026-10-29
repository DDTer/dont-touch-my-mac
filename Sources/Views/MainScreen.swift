import SwiftUI

struct MainScreen: View {
    @ObservedObject var model: GuardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(spacing: 11) {
                Image(systemName: "hand.raised.slash.fill").font(.system(size: 23, weight: .semibold)).foregroundStyle(lime)
                VStack(alignment: .leading, spacing: 4) {
                    Text("don’t touch my MAC!").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(model.t("app.tagline")).font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("V" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.10.3")).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                    Picker(model.t("language.label"), selection: $model.languageMode) {
                        ForEach(LanguageMode.allCases) { mode in
                            Text(model.localizer.modeName(mode)).tag(mode)
                        }
                    }.pickerStyle(.menu).controlSize(.small).frame(width: 205)
                }
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        if let image = model.customImage {
                            ZStack { Color.black; Image(nsImage: image).resizable().scaledToFit() }
                        } else { Poster(model: model) }
                    }
                    .frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Label(model.t("image.caption"), systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11)).foregroundStyle(muted)
                        Spacer()
                        Button(model.t("image.change")) { model.chooseImage() }.buttonStyle(.plain).foregroundStyle(lime).font(.system(size: 11, weight: .medium))
                        if model.customImage != nil {
                            Button(model.t("image.reset")) { model.customImage = nil; model.customName = nil }
                                .buttonStyle(.plain).foregroundStyle(muted).font(.system(size: 11))
                        }
                    }
                    if let name = model.customName {
                        Text(name).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text(model.t("privacy.local"))
                    }.font(.system(size: 10)).foregroundStyle(muted).padding(.top, 5)
                }.frame(width: 435)
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 7) {
                        Circle().fill(model.enabled ? lime : muted).frame(width: 6, height: 6)
                        Text(model.t(model.starting ? "status.starting" : model.enabled ? "status.on" : "status.off"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(model.enabled ? lime : muted)
                    }
                    Text(model.statusText).font(.system(size: 18, weight: .semibold))
                    Text(model.t("guard.instructions"))
                        .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    Button(action: { model.toggle() }) {
                        HStack {
                            Image(systemName: model.enabled ? "pause.fill" : "hand.raised.fill")
                            Text(model.t(model.enabled ? "guard.pause" : "guard.enable"))
                        }.font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(ink).background(lime, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                    Button(action: { model.preview() }) {
                        Label(model.t("guard.preview"), systemImage: "play.rectangle")
                            .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.09)))
                    }.buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(model.t("sensitivity.label")); Spacer(); Text(model.t(model.sensitivity > 0.7 ? "sensitivity.high" : model.sensitivity < 0.3 ? "sensitivity.low" : "sensitivity.medium")).foregroundStyle(muted) }
                            .font(.system(size: 11))
                        Slider(value: $model.sensitivity, in: 0...1).tint(lime)
                        Text(model.t("sensitivity.hint"))
                            .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Toggle(model.t("voice.enable"), isOn: $model.sound).toggleStyle(.checkbox).font(.system(size: 11)).tint(lime)
                        Spacer(minLength: 4)
                        Picker(model.t("voice.label"), selection: $model.voiceVariant) {
                            Text(model.t("voice.variant", "A")).tag(0)
                            Text(model.t("voice.variant", "B")).tag(1)
                            Text(model.t("voice.variant", "C")).tag(2)
                        }.labelsHidden().pickerStyle(.menu).controlSize(.mini).frame(width: 88)
                        Button(model.t("voice.audition")) { model.playWarningVoice(force: true) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(lime)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 16) {
                ZStack {
                    Color.black.opacity(0.3)
                    if model.enabled && !model.starting && !model.replaying {
                        CameraPreview(session: model.camera.session)
                    } else {
                        Image(systemName: "video.slash").font(.system(size: 20)).foregroundStyle(muted)
                    }
                }.frame(width: 130, height: 73).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.replaying ? model.t("camera.replayOff") : model.enabled ? model.motionText : model.t("camera.off"))
                        .font(.system(size: 11, weight: .medium))
                    Text(model.enabled ? model.t("camera.counts", String(model.handCount), String(model.triggers), String(model.recoveries)) : model.t("camera.permissionHint"))
                        .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(lime).frame(width: max(0, g.size.width * model.approachProgress))
                                Rectangle().fill(.white.opacity(0.7)).frame(width: 1).offset(x: g.size.width)
                            }
                        }.frame(height: 4)
                        Text("\(Int(model.approachProgress * 100))%")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).frame(width: 45)
                    }.frame(maxWidth: 260)
                }
                Spacer()
                Text(model.t("guard.shortcuts"))
                    .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(5).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }.padding(13).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(model.text(error)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(model.t("settings.open")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }.buttonStyle(.plain).foregroundStyle(lime)
                }.font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.72, blue: 0.45))
            }
        }
        .padding(25).frame(width: 790)
        .foregroundStyle(Color.white.opacity(0.93)).background(ink)
        .preferredColorScheme(.dark)
    }
}
