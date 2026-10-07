import Foundation

// doubao-reader helper 入口：与主 app 编译同一套 DoubaoAX/AXShared/QuotaValueParser 源文件，
// 动作/延迟/节流常量单一来源。独立二进制的 TCC 辅助功能授权与主 app 相互独立，作为 .noPage 兜底。
// 输出契约：读到观测打印 DoubaoReaderPayload.encode 的 JSON；否则打印 {}（主进程按无效载荷忽略）。
// 永不弹授权窗（allowPrompt=false），不读聊天内容，不写日志。
let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
switch DoubaoAX.collect(accountID: accountID, allowPrompt: false) {
case .observation(let obs):
    let payload = DoubaoReaderPayload.encode(obs)
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{}")
    }
default:
    print("{}")
}
