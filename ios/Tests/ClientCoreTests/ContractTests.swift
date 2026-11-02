import Foundation
import Testing
@testable import ClientCore

func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "backend", withExtension: "json", subdirectory: "Fixtures")!
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return try JSONSerialization.data(withJSONObject: root[name]!)
}

func fixture<Value: Decodable>(_ name: String, as: Value.Type = Value.self) throws -> Value {
    try JSONDecoder().decode(Value.self, from: fixtureData(name))
}

@Test @MainActor func backendResponsesDecode() throws {
    let snapshot: V2SessionSnapshot = try fixture("snapshot")
    #expect(snapshot.session.runtimeId == "rti_work")
    #expect(snapshot.state?.runtimeId == "rti_work")
    #expect(snapshot.state?.selections.keys.contains(.effort) == true)
    #expect(snapshot.timeline.items.first?.content == .message(V2MessageContent(rawContent: .object(["text": .string("Hello")]))))
    let types: V2RuntimeTypeListResponse = try fixture("runtimeTypes")
    let runtimes: V2DeviceRuntimeListResponse = try fixture("runtimes")
    #expect(V2RuntimeInventory(types: types.runtimeTypes, instances: runtimes.runtimes).canAdd(types.runtimeTypes[0]))
    let command: V2RuntimeCommandListResponse = try fixture("commands")
    #expect(command.commands.first?.argsSchema != nil)
    let _: V2WorkspaceDirectoryResponse = try fixture("rpcError")
    let _: V2AttachmentUploadResponse = try fixture("upload")
    let created: V2SessionCreateResponse = try fixture("createdSession")
    #expect(created.attachments?.first?.fileId == "file")
    #expect(created.attachments?.first?.reference(sessionID: "session").openUrl == "/api/v2/sessions/session/attachments/file/open")
    let _: V2AttachmentDownload = try fixture("download")
    let _: V2DashboardSnapshot = try fixture("dashboard")
    let _: V2EventRecoveryResponse = try fixture("recovery")
    let _: AuthMe = try fixture("profile")
}

@Test @MainActor func attachmentUploadAcceptsLegacyAndThumbnailResponses() throws {
    let legacy: V2AttachmentUploadResponse = try fixture("upload")
    #expect(legacy.attachments.first?.thumbnailUrl == nil)
    let original = try JSONSerialization.jsonObject(with: fixtureData("upload")) as! [String: Any]
    for thumbnail in ["", "/api/v2/sessions/session/attachments/file/thumb?w=512"] {
        var response = original
        var attachments = response["attachments"] as! [[String: Any]]
        attachments[0]["thumbnailUrl"] = thumbnail
        response["attachments"] = attachments
        let data = try JSONSerialization.data(withJSONObject: response)
        let decoded = try JSONDecoder().decode(V2AttachmentUploadResponse.self, from: data)
        #expect(decoded.attachments.first?.thumbnailUrl == thumbnail)
        #expect(decoded.attachments.first?.fileId == legacy.attachments.first?.fileId)
    }
}
