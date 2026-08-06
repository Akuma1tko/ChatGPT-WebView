import SwiftUI
import WebKit

struct SecureChatGPTWebView: UIViewRepresentable {
    @ObservedObject var store: ChatGPTWebViewStore

    func makeUIView(context: Context) -> WKWebView {
        store.loadIfNeeded()
        return store.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        store.loadIfNeeded()
    }
}
