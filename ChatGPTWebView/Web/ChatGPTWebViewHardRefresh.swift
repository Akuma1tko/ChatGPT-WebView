import Foundation

@MainActor
extension ChatGPTWebViewStore {
    func hardRefreshCurrentSession() async {
        let targetURL = webView.url ?? provider.startURL

        await persistProfileSession()
        webView.stopLoading()

        if let blankURL = URL(string: "about:blank") {
            webView.load(URLRequest(url: blankURL))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let request = URLRequest(
            url: targetURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        webView.load(request)

        var observedLoading = webView.isLoading
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            observedLoading = observedLoading || webView.isLoading
            if observedLoading && !webView.isLoading {
                break
            }
        }
    }
}
