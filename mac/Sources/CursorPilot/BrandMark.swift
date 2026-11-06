import SwiftUI
import WebKit

/// The "cursorpilot" wordmark at the top of Home: the melted, liquid mark
/// from the website, drawn live in a transparent web view (it bulges under
/// the pointer and wobbles when clicked). The page is a licensed component
/// built outside this repository; builds without it show the name as text.
struct BrandMark: View {
    private static let page = Bundle.main.url(forResource: "melt-mark", withExtension: "html")

    var body: some View {
        if let page = Self.page {
            MeltMarkWebView(page: page)
                .accessibilityLabel("Cursor Pilot")
        } else {
            Text("cursorpilot")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MeltMarkWebView: NSViewRepresentable {
    var page: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
