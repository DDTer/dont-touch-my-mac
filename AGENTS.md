# Don't Touch My Mac

- 原生 SwiftUI/AppKit macOS 工具，最低 macOS 14；`project.yml` 是 XcodeGen 工程源，生成的 `.xcodeproj` 也提交，便于直接用 Xcode 打开。
- 构建和相关验证：`./Scripts/build.sh`。已有检测状态机回归与本地化检查通过后交付，不额外堆叠测试流程。
- 所有应用文案放在 `Resources/{en,ja,zh-Hans}.lproj/Localizable.strings`，三份保持键与占位符一致；错误、菜单和警告画面也要覆盖。手动语言不修改系统 `AppleLanguages`。
- 配音为内置 WAV，放 `Assets/Voices/{en,ja,zh}-{a,b,c}.wav`，运行无需 API。不要把 API 凭证或 `.env` 放进仓库。
- 不提交构建产物、原始相机/手部诊断记录或测试启动标记；仅保留脱敏验证摘要。
- 检测属于单目视觉启发式，不能把模拟或数据回放结果写成独立真人实测通过；保留 README 的限制。
