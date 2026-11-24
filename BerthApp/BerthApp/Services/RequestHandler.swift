import Foundation

/// Answers every socket event in docs/contract.md.
final class RequestHandler: @unchecked Sendable {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ line: Data) async -> Data {
        switch BerthRequest.parse(line) {
        case .failure(let error):
            return Reply.failure(error)
        case .success(let request):
            return await handle(request)
        }
    }

    private func handle(_ request: BerthRequest) async -> Data {
        switch request {
        case .status:
            return Reply.ok(await MainActor.run { model.statusData() })

        case .open(let url):
            let result = await MainActor.run { model.open(url) }
            switch result {
            case .success(let data): return Reply.ok(data)
            case .failure(let error): return Reply.failure(error)
            }

        case .reload:
            return Reply.ok(await model.configStore.reload())

        case .signinFill:
            return Reply.failure(.signinNotImplemented)
        }
    }
}
