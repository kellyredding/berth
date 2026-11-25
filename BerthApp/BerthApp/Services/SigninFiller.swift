import Foundation
import WebKit

/// Runs one `signin.fill` in a window's web view: polls the page with
/// SigninScript, lets SigninRun decide, and fills or waits. It logs the steps
/// and the selectors that matched, never a value, and drops the values when
/// it returns. `progress` follows the step and what it waits on, for the
/// sign-in bar.
@MainActor
final class SigninFiller: ObservableObject {
    private static let poll: UInt64 = 400_000_000

    private weak var webView: WKWebView?
    @Published private(set) var progress: SigninProgress?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func run(_ request: SigninRequest, siteHost: String?) async -> SigninData {
        let steps = request.steps.map {
            SigninRun.Step(flow: $0.flow, hasPassword: $0.password != nil, hasCode: $0.code != nil, method: $0.method)
        }
        var run = SigninRun(steps: steps, siteHost: siteHost, start: Date())
        var lastIndex = -1
        var lastWaiting: String?

        while true {
            guard let webView else {
                return SigninData(completed: run.completed, stoppedAt: SigninStop(
                    step: run.index, flow: run.currentFlow?.rawValue ?? "", reason: "the window closed"
                ), url: nil, alreadySignedIn: false)
            }
            if run.index != lastIndex, let flow = run.currentFlow {
                lastIndex = run.index
                Log.info("signin: step \(run.index + 1) of \(steps.count), \(flow.rawValue)")
                report(run)
            }
            let page = await observe(run.index < request.steps.count ? request.steps[run.index] : nil, in: webView)
            let decision = run.next(page, now: Date())
            if run.waitingReason != lastWaiting {
                lastWaiting = run.waitingReason
                if let reason = lastWaiting { Log.info("signin: \(run.currentFlow?.rawValue ?? ""): \(reason)") }
                report(run)
            }

            switch decision {
            case .finish(let outcome):
                return SigninData(
                    completed: outcome.completed, stoppedAt: outcome.stoppedAt,
                    url: webView.url.map(AppModel.describe), alreadySignedIn: outcome.alreadySignedIn
                )
            case .wait:
                break
            case .fill(let fields):
                let values = request.steps[run.index]
                let filled = await fill(fields, values: values, flow: values.flow, in: webView)
                run.filled(filled, at: Date())
            case .choose:
                await choose(request.steps[run.index], in: webView)
                run.choseAccount()
            case .chooseMethod(let method):
                if await chooseMethod(method, flow: request.steps[run.index].flow, in: webView) {
                    run.choseMethod(at: Date())
                }
            }
            try? await Task.sleep(nanoseconds: Self.poll)
        }
    }

    private func report(_ run: SigninRun) {
        guard let flow = run.currentFlow else { return }
        let next = SigninProgress(step: run.index, count: run.steps.count, flow: flow.rawValue, waitingReason: run.waitingReason)
        if next != progress { progress = next }
    }

    /// Whether the page shows any of these flows' marker elements, as the
    /// fill's own observation sees them: a flow's sign-in page served from a
    /// host it does not list (a custom domain, a local fixture).
    static func showsMarker(of flows: [SigninFlow], in webView: WKWebView) async -> Bool {
        for flow in flows {
            let result = await call(["op": "observe", "spec": flow.spec.scriptArgument, "method": NSNull()], in: webView)
            if (result as? [String: Any])?["marker"] is String { return true }
        }
        return false
    }

    private func call(_ request: [String: Any], in webView: WKWebView) async -> Any? {
        await Self.call(request, in: webView)
    }

    private static func call(_ request: [String: Any], in webView: WKWebView) async -> Any? {
        do {
            return try await webView.callAsyncJavaScript(
                SigninScript.body, arguments: ["request": request], in: nil, contentWorld: .defaultClient
            )
        } catch {
            // A page navigating away mid-call is routine; the next poll sees the new one.
            return nil
        }
    }

    private func observe(_ values: SigninValues?, in webView: WKWebView) async -> PageObservation? {
        guard let values else { return nil }
        let result = await call(
            ["op": "observe", "spec": values.flow.spec.scriptArgument, "method": values.method.map { $0 as Any } ?? NSNull()], in: webView
        )
        return PageObservation(script: result, loading: webView.isLoading)
    }

    private func fill(_ fields: [SigninField], values: SigninValues, flow: SigninFlow,
                      in webView: WKWebView) async -> [SigninField] {
        let fills: [[String: Any]] = fields.compactMap { field in
            values.value(field).map { ["field": field.rawValue, "value": $0] }
        }
        let result = await call(["op": "fill", "spec": flow.spec.scriptArgument, "fills": fills], in: webView)
        guard let fields = result as? [String: Any] else { return [] }
        if let missing = fields["missing"] as? String {
            Log.info("signin: \(flow.rawValue): the \(missing) field went away before it was filled")
            return []
        }
        let filled = (fields["filled"] as? [[String: Any]] ?? []).compactMap { item -> (SigninField, String)? in
            guard let name = item["field"] as? String, let field = SigninField(rawValue: name) else { return nil }
            return (field, item["selector"] as? String ?? "?")
        }
        let matched = filled.map { "\($0.0.rawValue) (\($0.1))" }.joined(separator: ", ")
        Log.info("signin: \(flow.rawValue): filled \(matched); submitted with \(fields["submitted"] as? String ?? "nothing")")
        return filled.map(\.0)
    }

    /// Whether the method's button was clicked; if not, the next poll looks again.
    private func chooseMethod(_ method: String, flow: SigninFlow, in webView: WKWebView) async -> Bool {
        let result = await call(["op": "method", "spec": flow.spec.scriptArgument, "method": method], in: webView) as? [String: Any]
        let clicked = result?["clicked"] as? String
        Log.info("signin: \(flow.rawValue): verification method: \(clicked.map { "chose \($0)" } ?? "\(method) not found")")
        return clicked != nil
    }

    private func choose(_ values: SigninValues, in webView: WKWebView) async {
        let result = await call(
            ["op": "choose", "spec": values.flow.spec.scriptArgument, "identifier": values.username], in: webView
        ) as? [String: Any]
        let clicked = result?["clicked"] as? String
        Log.info("signin: \(values.flow.rawValue): account chooser: \(clicked.map { "clicked \($0)" } ?? "nothing to click")")
    }
}
