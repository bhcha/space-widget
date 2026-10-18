import Foundation
import Darwin

/// Installation health endpoint in the durable native executable. It never opens a window,
/// reads a transcript, or writes the inbound payload. Only allowlisted event metadata is queued.
enum HookInstallationReceiver {
    static func run(arguments: [String], input: Int32 = STDIN_FILENO,
                    diagnostics: HookDiagnostics = .live,
                    capture: () -> AgentLaunchContext = AgentLaunchContext.capture) {
        guard arguments.count == 5, arguments[1] == "--spacewidget-hook",
              let agent = LocalAgent(rawValue: arguments[2]), arguments[3].hasPrefix("/"),
              HookInstallation.events.contains(arguments[4]) else { return }
        let installation = HookInstallation(agent: agent, directory: URL(fileURLWithPath: arguments[3]))
        let invocation = UUID().uuidString
        let fields = ["invocation": invocation, "agent": agent.rawValue, "kind": arguments[4],
                      "helper_version": String(installation.helperVersion)]
        diagnostics.emit("receiver.started", fields: fields)
        var outcome = "input_rejected"
        defer { diagnostics.emit("receiver.finished", fields: fields.merging(["outcome": outcome]) { _, new in new }) }
        // Bounded input and deadline even when invoked outside an agent with no timeout.
        let deadline = Date().addingTimeInterval(1)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 25) >= 0 else { return }
            if descriptor.revents & Int16(POLLIN | POLLHUP) == 0 { continue }
            let count = read(input, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= 262_144 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard Date() < deadline,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var event = AgentHookEvent.parse(object, installation: installation,
                                               expectedKind: arguments[4]) else { return }
        diagnostics.emit("receiver.parsed", event: event, fields: fields)
        if event.kind == "SessionStart" || event.kind == "UserPromptSubmit" {
            let context = capture()
            event.origin = context.origin
            event.originCapturePolicy = context.origin == nil ? nil : AgentSpaceCapture.policy
            event.application = context.application
            diagnostics.emit("capture.completed", event: event, fields: context.diagnostics.merging(fields) { _, new in new })
        }
        do {
            try installation.rejectLinks(installation.receipt)
            switch installation.inspect() {
            case .pendingTrust, .awaitingExecution, .connected: break
            default: outcome = "installation_not_ready"; return
            }
            let config = try Data(contentsOf: installation.file)
            let helper = try Data(contentsOf: installation.helper)
            let receipt = HookInstallationReceipt(configurationDigest: HookInstallation.digest(config),
                                                   helperDigest: HookInstallation.digest(helper))
            try JSONEncoder().encode(receipt).write(to: installation.receipt, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installation.receipt.path)
            let accepted = try HookEventTransport(installation: installation, diagnostics: diagnostics).enqueue(event)
            outcome = accepted ? "committed" : "duplicate"
            diagnostics.emit("receiver.enqueued", event: event, fields: ["invocation": invocation, "accepted": String(accepted)])
        } catch {
            outcome = "transport_or_receipt_failed"
            let error = error as NSError
            diagnostics.emit("receiver.failed", event: event, fields: ["invocation": invocation,
                "error_domain": error.domain, "error_code": String(error.code)])
        }
    }
}
