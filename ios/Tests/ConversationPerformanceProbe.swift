// Synthetic, offline UI layout probe. Installed only by probe-conversation-performance.py.
import SwiftUI
import UIKit
import Foundation
import Synchronization

nonisolated struct ProbeHTTP: HTTPTransport {
    func send<Body: Encodable, Response: Decodable>(_ request: HTTPRequest<Body,Response>) async throws -> Response { throw URLError(.notConnectedToInternet) }
    func upload<Response:Decodable>(_ request:HTTPUploadRequest<Response>) async throws -> Response { throw URLError(.notConnectedToInternet) }
    func download(_ url:URL) async throws -> URL { throw URLError(.notConnectedToInternet) }
}
nonisolated struct ProbeRealtime: V2RealtimeAPIProtocol {
    func ticket(clientId:String,scope:V2RealtimeScope) async throws -> V2WebSocketTicket { throw URLError(.notConnectedToInternet) }
    func recover(sessionId:V2SessionID,after cursor:String) async throws -> V2EventRecoveryResponse { throw URLError(.notConnectedToInternet) }
    func sessionEvents(sessionId:V2SessionID,ticket:String) throws -> AsyncThrowingStream<V2SessionEvent,Error> { AsyncThrowingStream { $0.finish() } }
    func dashboardSnapshots(ticket:String) throws -> AsyncThrowingStream<V2DashboardSnapshot,Error> { AsyncThrowingStream { $0.finish() } }
}
@MainActor final class ProbeModels {
    static func snapshotData(count:Int, review:Bool = false) throws -> Data {
        let fixtureURL=Bundle.main.url(forResource:"ConversationProbeFixtures",withExtension:"json")!
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:fixtureURL)) as! [String:Any]
        var snapshot=fixture["snapshot"] as! [String:Any]
        var timeline=snapshot["timeline"] as! [String:Any]
        let template=(timeline["items"] as! [[String:Any]])[0]
        let items=(0..<count).map { index -> [String:Any] in
            var item=template
            item["id"]="probe-\(index)"; item["orderSeq"]=index+1; item["turnId"]="turn-\(index/3)"; item["status"]="done"; item["type"]="message"; item["role"]=index%3 == 0 ? "user" : "assistant"
            var text = index%3 == 0 ? "用户输入 \(index)\n"+String(repeating:"这是一段用于旋转排版的合成输入，包含多行文字，帮助复现长输入的布局成本。\n", count:index%30 == 0 ? 100 : 2) : "### 回复 \(index)\n\n这是一段合成 Markdown **正文**，用于相同内容和配置下的布局对比。\n\n- 第一条\n- 第二条\n\n`sample_code()`"
            if !review && ProcessInfo.processInfo.arguments.contains("--stress") {
                if index == 0 { text=String(String(repeating:"合成的超长用户输入，用于压力排版测试。\n",count:3000).prefix(50_000)) }
                else {
                    let paragraph="## 压力段落\n\n"+String(repeating:"这是一段长篇 Markdown 正文，包含重点、文字排版和段落换行。",count:80)+"\n\n```swift\nlet value = 42\nprint(value)\n```\n\n| 项目 | 内容 |\n| --- | --- |\n| 状态 | 合成测试 |\n\n"
                    text=String(String(repeating:paragraph,count:30).prefix(50_000))
                }
            }
            if review && index == 6 { text = "<heartbeat>\n<automation_id>probe-review</automation_id>\n<current_time_iso>2026-10-29T00:00:00Z</current_time_iso>\n<instructions>这是一条应默认隐藏的合成自动化运行指令。</instructions>\n</heartbeat>" }
            if review && index == 7 { text = "<heartbeat>\n<automation_id>probe-review</automation_id>\n<decision>DONT_NOTIFY</decision>\n<message>没有新的进展。</message>\n</heartbeat>" }
            if review && index == 9 { text = "<heartbeat>\n<automation_id>probe-notify</automation_id>\n<instructions>合成通知任务的内部运行指令。</instructions>\n</heartbeat>" }
            if review && index == 10 { text = "<heartbeat>\n<automation_id>probe-notify</automation_id>\n<decision>NOTIFY</decision>\n<message>合成通知：新的结果已准备好，请查看附件与下一步。</message>\n</heartbeat>" }
            item["content"]=["text":text]; return item
        }
        timeline["items"]=items; timeline["hasMore"]=false; snapshot["timeline"]=timeline; snapshot["notices"]=[]
        return try JSONSerialization.data(withJSONObject:snapshot)
    }
    static func model(count:Int) throws -> SessionChatModel {
        let value=try JSONDecoder().decode(V2SessionSnapshot.self,from:snapshotData(count:count))
        let transport=ProbeHTTP(); let runtime=V2RuntimeAPI(transport:transport)
        let detail=V2SessionDetailService(sessionAPI:V2SessionAPI(transport:transport),runtimeAPI:runtime,realtimeAPI:ProbeRealtime())
        let repository=V2SessionRepository(scope:V2ClientScope(serverURL:URL(string:"https://probe.invalid/api/v2")!,accountID:"probe"),detail:detail,interactions:V2RuntimeInteractionService(runtimeAPI:runtime))
        let session=repository.session(id:value.session.id)
        let projection=V2SessionProjection(snapshot:value,maximumItems:1000)
        session.update(V2SessionObservation(sessionId:session.id,data:projection.data,connection:.connected,error:nil),network:V2NetworkStatus())
        let chat=SessionChatModel(session:session,repository:repository,attachments:V2AttachmentService(attachmentAPI:V2AttachmentAPI(transport:transport)))
        chat.timeline.presentOpening(projection.data.items,pendingMessages:[])
        return chat
    }
}
@MainActor struct ProbeContent:View {
    let model:SessionChatModel
    var body:some View {
        ScrollView {
            ChatTimelineContent(model:model,onAttachment:{_ in},onFile:{_ in},latestPullReady:false,isLoadingLatest:false,olderPullReady:false,isLoadingOlder:false,keepsOlderPrompt:false,historyAnchor:nil,onLoadOlder:{},onLoadLatest:{},onHistoryLayout:{_ in},onPromptVisibility:{_ in},onOlderPromptVisibility:{_ in},onTailVisibility:{_,_ in})
        }.background(Color.white)
    }
}
@MainActor final class ProbeController:UIViewController {
    private var didRun=false
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        guard !didRun else { return }; didRun=true
        Task { await run() }
    }
    func run() async {
        var rows:[[String:Any]]=[]
        do {
            for count in (ProcessInfo.processInfo.arguments.contains("--stress") ? [2] : [100,300,1000]) {
                let model=try ProbeModels.model(count:count)
                let host=UIHostingController(rootView:ProbeContent(model:model))
                addChild(host); view.addSubview(host.view); host.didMove(toParent:self)
                host.view.frame=CGRect(x:0,y:0,width:390,height:750)
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                try await Task.sleep(for:.seconds(3))
                var samples:[Double]=[]
                for index in 0..<12 {
                    let width:CGFloat=index%2 == 0 ? 760 : 390
                    let start=CACurrentMediaTime()
                    host.view.frame=CGRect(x:0,y:0,width:width,height:750)
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    let elapsed=(CACurrentMediaTime()-start)*1000
                    samples.append(elapsed)
                    try await Task.sleep(for:.milliseconds(160))
                }
                var usage=rusage(); getrusage(RUSAGE_SELF,&usage)
                rows.append(["items":count,"widths":[390,760],"layout_ms":samples,"peak_rss_bytes":usage.ru_maxrss])
                let partial:[String:Any]=["kind":"release_simulator_controlled_width_reflow","synthetic":true,"physical_device":false,"complete":false,"rows":rows]
                let partialURL=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("conversation-performance-partial.json")
                try JSONSerialization.data(withJSONObject:partial,options:[.prettyPrinted,.sortedKeys]).write(to:partialURL)
                host.willMove(toParent:nil);host.view.removeFromSuperview();host.removeFromParent()
                try await Task.sleep(for:.milliseconds(250))
            }
            let result:[String:Any]=["kind":"release_simulator_controlled_width_reflow","synthetic":true,"physical_device":false,"complete":true,"stress_50k_pair":ProcessInfo.processInfo.arguments.contains("--stress"),"os":UIDevice.current.systemVersion,"device":UIDevice.current.model,"rows":rows]
            let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("conversation-performance.json")
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url)
            view.backgroundColor = .systemGreen
            let label=UILabel(frame:CGRect(x:25,y:100,width:330,height:150)); label.text=ProcessInfo.processInfo.arguments.contains("--stress") ? "合成压力采样完成\n50k 用户输入 + 50k Markdown" : "布局基线采样完成\n合成会话 100 / 300 / 1000 条";label.numberOfLines=0;view.addSubview(label)
        } catch { view.backgroundColor = .systemRed; print("PROBE_FAILED") }
    }
}
struct ProbeScreen:UIViewControllerRepresentable {
    func makeUIViewController(context:Context)->ProbeController { ProbeController() }
    func updateUIViewController(_ controller:ProbeController,context:Context) {}
}
nonisolated final class ProbeURLProtocol:URLProtocol, @unchecked Sendable {
    static let responses=Mutex<[String:Data]>([:])
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard let url=request.url, url.host == "probe.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet));return }
        let path=url.path
        guard !path.hasSuffix("/ws-ticket"), let data=Self.responses.withLock({ values in values.first { path.hasSuffix("/"+$0.key) }?.value }) else { client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet));return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor struct ReviewScreen:View {
    @State private var services:V2ClientServices
    @State private var session:V2SessionModel
    init() {
        let data=try! ProbeModels.snapshotData(count:12,review:true)
        let snapshot=try! JSONDecoder().decode(V2SessionSnapshot.self,from:data)
        let fixtures=try! JSONSerialization.jsonObject(with:Data(contentsOf:Bundle.main.url(forResource:"ConversationProbeFixtures",withExtension:"json")!)) as! [String:Any]
        var responses:[String:Data]=["snapshot":data]
        for (path,key) in ["state":"state","capabilities":"capabilities","notices":"notices","catalogs/model":"modelCatalog","catalogs/permission":"permissionCatalog","commands":"commands"] { responses[path]=try! JSONSerialization.data(withJSONObject:fixtures[key]!) }
        ProbeURLProtocol.responses.withLock { $0=responses }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ProbeURLProtocol.self]
        let api=V2APIClient(serverURL:URL(string:"https://probe.invalid/api/v2")!,tokenProvider:StaticAuthTokenProvider(token:"synthetic-offline-probe"),urlSession:URLSession(configuration:config))
        let services=V2ClientServices(api:api,accountID:"synthetic-probe-\(UUID().uuidString)")
        _services=State(initialValue:services);_session=State(initialValue:services.sessionRepository.session(id:snapshot.session.id))
    }
    var body:some View {
        NavigationStack {
            SessionChatView(session:session,services:services,deviceName:"离线合成设备",onMenu:{})
        }
    }
}
@main struct AgentsAnywhereApp:App {
    var body:some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--review") { ReviewScreen() }
            else { ProbeScreen().ignoresSafeArea() }
        }
    }
}
