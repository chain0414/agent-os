import Foundation

// Compare actual compiled resources with the feature's source catalog entries.
// This checks packaging/locale lookup, not translation quality or ASR accuracy.
guard CommandLine.arguments.count == 2 else { fatalError("Pass the built app bundle") }
let product = URL(fileURLWithPath: CommandLine.arguments[1])
let catalogs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Agents Anywhere/Agents Anywhere/Resources/Localization")
let keys = [
    "语音输入", "结束录音", "取消录音", "转成文字后，确认再发送。", "打开设置",
    "正在准备语音输入…", "正在录音…", "正在完成转写…",
    "请在系统设置中允许麦克风访问后重试。",
    "语音输入暂不可用，请稍后重试。",
    "无法连接语音服务，请检查网络后重试。",
    "登录已失效，请重新登录后使用语音输入。",
    "服务器暂不支持语音输入，请稍后重试。",
    "语音输入请求过于频繁，请稍后重试。",
    "麦克风暂不可用，请检查音频设备后重试。",
    "语音识别失败，已保留识别出的文字，请重试。",
    "录音已中断，已保留识别出的文字。", "没有识别到语音，请重试。",
]
var checks = 0
for table in ["Localizable", "InfoPlist"] {
    let data = try Data(contentsOf: catalogs.appendingPathComponent("\(table).xcstrings"))
    let catalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let entries = catalog["strings"] as! [String: [String: Any]]
    for language in ["en", "zh-Hans"] {
        let bundle = Bundle(url: product.appendingPathComponent("\(language).lproj"))!
        for key in table == "Localizable" ? keys : ["NSMicrophoneUsageDescription"] {
            let localizations = entries[key]!["localizations"] as! [String: [String: Any]]
            let expected = (localizations[language]!["stringUnit"] as! [String: String])["value"]!
            let actual = bundle.localizedString(forKey: key, value: nil, table: table)
            guard actual == expected else { fatalError("Compiled voice localization differs: \(language) \(key)") }
            checks += 1
        }
    }
}
print("Passed \(checks) compiled voice input localization and microphone permission checks.")
