//
//  BrowserView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI
import WebKit

/// WKWebView subclass that reports page interaction back to the pane layout.
/// WebKit's actual first responder is a private descendant view, so observing
/// the outer SwiftUI host is not enough to keep pane focus in sync.
final class BrowserWebView: WKWebView {
    var onFocused: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocused?()
        super.rightMouseDown(with: event)
    }
}

/// The long-lived state of one browser pane. The WKWebView belongs to the
/// model, rather than the transient SwiftUI representable, so switching tabs
/// preserves page state, history, forms, and scroll position.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    nonisolated let id = UUID()

    @Published private(set) var title = String(localized: "New Tab")
    @Published private(set) var urlString = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var errorMessage: String?
    /// Incremented by the app-level Focus Address Bar command. A sequence is
    /// used instead of a Bool so repeated ⌘L presses are never coalesced.
    @Published private(set) var focusAddressRequest: UInt = 0

    let webView: BrowserWebView

    private var pageTitle: String?
    private var observations: Set<AnyCancellable> = []
    private var focusesAddressBarOnFirstAppearance: Bool

    init(initialURL: String? = nil, focusesAddressBar: Bool = true) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true

        webView = BrowserWebView(frame: .zero, configuration: configuration)
        focusesAddressBarOnFirstAppearance = focusesAddressBar
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observeWebView()

        if let initialURL, !initialURL.isEmpty {
            navigate(to: initialURL)
        }
    }

    var snapshotURL: String? {
        urlString.isEmpty ? nil : urlString
    }

    var shareURL: URL? {
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    var isBlank: Bool {
        urlString.isEmpty
    }

    func consumeInitialAddressFocus() -> Bool {
        guard focusesAddressBarOnFirstAppearance else { return false }
        focusesAddressBarOnFirstAppearance = false
        return true
    }

    func requestAddressFocus() {
        focusAddressRequest &+= 1
    }

    func navigate(to address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.destination(for: trimmed) else { return }
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else if !isBlank {
            errorMessage = nil
            webView.reload()
        }
    }

    func reload() {
        guard !isBlank else { return }
        errorMessage = nil
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func openInDefaultBrowser() {
        guard let shareURL else { return }
        NSWorkspace.shared.open(shareURL)
    }

    private func observeWebView() {
        webView.publisher(for: \.title, options: [.initial, .new])
            .sink { [weak self] title in
                self?.pageTitle = title
                self?.refreshTitle()
            }
            .store(in: &observations)

        webView.publisher(for: \.url, options: [.initial, .new])
            .sink { [weak self] url in
                guard let self else { return }
                self.urlString = Self.displayAddress(for: url)
                self.refreshTitle()
            }
            .store(in: &observations)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .sink { [weak self] in self?.canGoBack = $0 }
            .store(in: &observations)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .sink { [weak self] in self?.canGoForward = $0 }
            .store(in: &observations)

        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self] in self?.isLoading = $0 }
            .store(in: &observations)

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .sink { [weak self] in self?.estimatedProgress = $0 }
            .store(in: &observations)
    }

    private func refreshTitle() {
        if let pageTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pageTitle.isEmpty {
            title = pageTitle
        } else if let host = webView.url?.host, !host.isEmpty {
            title = host
        } else {
            title = String(localized: "New Tab")
        }
    }

    private static func displayAddress(for url: URL?) -> String {
        guard let url,
              url.absoluteString != "about:blank",
              url.scheme != nil
        else { return "" }
        return url.absoluteString
    }

    /// Turns the Safari-style combined address/search field into a request.
    /// Explicit URLs are preserved, likely hostnames gain a scheme, and
    /// everything else becomes a web search.
    private static func destination(for input: String) -> URL? {
        let lowercased = input.lowercased()
        let explicitPrefixes = [
            "http://", "https://", "file://", "about:", "data:",
        ]
        if explicitPrefixes.contains(where: lowercased.hasPrefix) {
            return urlAllowingSpaces(input)
        }

        if !input.contains(where: \.isWhitespace), looksLikeHost(input) {
            let host = host(in: input).lowercased()
            let useHTTP = host == "localhost"
                || host.hasSuffix(".local")
                || isIPv4(host)
                || host.hasPrefix("[::")
                || hasExplicitPort(input)
            return urlAllowingSpaces("\(useHTTP ? "http" : "https")://\(input)")
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: input)]
        return components?.url
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        let host = host(in: input)
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        if host.hasPrefix("[") && host.contains("]") { return true }
        if host.contains(".") { return true }
        return hasExplicitPort(input)
    }

    private static func host(in input: String) -> String {
        let authority = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            return String(authority[...bracket])
        }
        return authority.split(separator: ":", maxSplits: 1).first.map(String.init)
            ?? authority
    }

    private static func isIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4
            && components.allSatisfy {
                guard let octet = Int($0) else { return false }
                return (0...255).contains(octet)
            }
    }

    private static func hasExplicitPort(_ input: String) -> Bool {
        let authority = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            let remainder = authority[authority.index(after: bracket)...]
            return remainder.first == ":" && Int(remainder.dropFirst()) != nil
        }
        guard let colon = authority.lastIndex(of: ":") else { return false }
        return Int(authority[authority.index(after: colon)...]) != nil
    }

    private static func urlAllowingSpaces(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        return string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        showNavigationError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        showNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorMessage = String(localized: "The webpage stopped responding.")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased()
        else {
            decisionHandler(.allow)
            return
        }
        let handledSchemes = ["http", "https", "file", "about", "data", "blob"]
        if handledSchemes.contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    private func showNavigationError(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        errorMessage = nsError.localizedDescription
    }

    // MARK: - WKUIDelegate

    /// Keep target=_blank links inside this browser tab. Kero has an explicit
    /// tab command, so webpages should not create detached, chrome-less
    /// WKWebView windows.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? String(localized: "Webpage")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert, for: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? String(localized: "Webpage")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? String(localized: "Webpage")
        alert.informativeText = prompt
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        present(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func present(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// Browser content and native navigation chrome. The toolbar stays in SwiftUI
/// so it follows Kero's appearance while the page remains a real WKWebView.
struct BrowserView: View {
    @ObservedObject var browser: BrowserTab
    let onFocused: () -> Void

    @ObservedObject private var themeChanges = Theme.changes
    @State private var address = ""
    @State private var addressFocused = false
    @State private var addressFocusRequest: UInt = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                BrowserWebViewRepresentable(browser: browser, onFocused: onFocused)

                if browser.isBlank {
                    Color(nsColor: Theme.background)
                        .overlay {
                            Image(systemName: "globe")
                                .font(.system(size: 34, weight: .ultraLight))
                                .foregroundStyle(.tertiary)
                        }
                        .allowsHitTesting(false)
                }

                if let errorMessage = browser.errorMessage {
                    errorState(errorMessage)
                }
            }
            .overlay(alignment: .top) {
                progress
            }
        }
        .background(Color(nsColor: Theme.background))
        .onAppear {
            address = browser.urlString
            if browser.consumeInitialAddressFocus() {
                focusAddressField()
            }
        }
        .onChange(of: browser.urlString) { _, value in
            if !addressFocused {
                address = value
            }
        }
        .onChange(of: browser.focusAddressRequest) {
            focusAddressField()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                toolbarButton(
                    "chevron.left",
                    help: String(localized: "Back"),
                    disabled: !browser.canGoBack,
                    action: browser.goBack
                )
                toolbarButton(
                    "chevron.right",
                    help: String(localized: "Forward"),
                    disabled: !browser.canGoForward,
                    action: browser.goForward
                )
                toolbarButton(
                    browser.isLoading ? "xmark" : "arrow.clockwise",
                    help: browser.isLoading
                        ? String(localized: "Stop")
                        : String(localized: "Reload Page (⌘R)"),
                    disabled: browser.isBlank && !browser.isLoading,
                    action: browser.reloadOrStop
                )
            }
            .frame(width: 94, alignment: .leading)

            Spacer(minLength: 0)
            addressField
                .frame(maxWidth: 720)
            Spacer(minLength: 0)

            HStack(spacing: 2) {
                if let url = browser.shareURL {
                    ShareLink(item: url) {
                        toolbarIcon("square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded(onFocused))
                    .help(String(localized: "Share"))
                    .accessibilityLabel(String(localized: "Share"))
                } else {
                    toolbarIcon("square.and.arrow.up")
                        .foregroundStyle(.quaternary)
                        .accessibilityHidden(true)
                }

                toolbarButton(
                    "arrow.up.right.square",
                    help: String(localized: "Open in Default Browser"),
                    disabled: browser.shareURL == nil,
                    action: browser.openInDefaultBrowser
                )
            }
            .frame(width: 94, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color(nsColor: Theme.background))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: addressIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)

            BrowserAddressField(
                text: $address,
                focusRequest: addressFocusRequest,
                onFocus: {
                    addressFocused = true
                    onFocused()
                },
                onBlur: {
                    addressFocused = false
                },
                onSubmit: {
                    browser.navigate(to: address)
                },
                onCancel: {
                    address = browser.urlString
                }
            )
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(addressFocused ? 0.09 : 0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    addressFocused
                        ? Color(nsColor: Theme.accent).opacity(0.65)
                        : Color.primary.opacity(0.08),
                    lineWidth: addressFocused ? 1.5 : 1
                )
        )
    }

    private var addressIcon: String {
        if browser.isBlank { return "magnifyingglass" }
        guard let url = browser.webView.url else { return "magnifyingglass" }
        switch url.scheme?.lowercased() {
        case "https": return "lock.fill"
        case "http": return "globe"
        default: return "doc"
        }
    }

    @ViewBuilder
    private var progress: some View {
        if browser.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color(nsColor: Theme.accent))
                    .frame(
                        width: geometry.size.width
                            * max(0.04, min(1, browser.estimatedProgress))
                    )
            }
            .frame(height: 2)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func toolbarButton(
        _ systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onFocused()
            action()
        } label: {
            toolbarIcon(systemImage)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func toolbarIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("This webpage couldn’t be loaded.")
                .font(.headline)
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Try Again") {
                browser.reload()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
    }

    private func focusAddressField() {
        addressFocusRequest &+= 1
    }
}

/// NSTextField owns a private field editor while it is active. Selecting from a
/// SwiftUI focus callback happens during mouse-down, then that editor collapses
/// the selection again on mouse-up. Consume the inactive field's first click
/// and select through the native editor; subsequent clicks can place the caret.
private final class BrowserAddressTextField: NSTextField {
    var isActivelyEditing = false

    override func mouseDown(with event: NSEvent) {
        guard isActivelyEditing else {
            selectText(nil)
            return
        }
        super.mouseDown(with: event)
    }

    func focusAndSelectAll() {
        selectText(nil)
    }
}

private struct BrowserAddressField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusRequest: focusRequest,
            onFocus: onFocus,
            onBlur: onBlur,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> BrowserAddressTextField {
        let field = BrowserAddressTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = .labelColor
        field.placeholderString = String(localized: "Search or enter website name")
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.setAccessibilityLabel(String(localized: "Search or enter website name"))
        return field
    }

    func updateNSView(_ field: BrowserAddressTextField, context: Context) {
        context.coordinator.update(from: self)
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        guard focusRequest != context.coordinator.handledFocusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in
            field?.focusAndSelectAll()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var handledFocusRequest: UInt
        private var onFocus: () -> Void
        private var onBlur: () -> Void
        private var onSubmit: () -> Void
        private var onCancel: () -> Void

        init(
            text: Binding<String>,
            focusRequest: UInt,
            onFocus: @escaping () -> Void,
            onBlur: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            handledFocusRequest = focusRequest
            self.onFocus = onFocus
            self.onBlur = onBlur
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func update(from field: BrowserAddressField) {
            text = field.$text
            onFocus = field.onFocus
            onBlur = field.onBlur
            onSubmit = field.onSubmit
            onCancel = field.onCancel
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? BrowserAddressTextField)?.isActivelyEditing = true
            onFocus()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? BrowserAddressTextField)?.isActivelyEditing = false
            onBlur()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                text.wrappedValue = textView.string
                onSubmit()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

private struct BrowserWebViewRepresentable: NSViewRepresentable {
    @ObservedObject var browser: BrowserTab
    let onFocused: () -> Void

    func makeNSView(context: Context) -> BrowserWebView {
        browser.webView.onFocused = onFocused
        return browser.webView
    }

    func updateNSView(_ webView: BrowserWebView, context: Context) {
        webView.onFocused = onFocused
    }

    static func dismantleNSView(_ webView: BrowserWebView, coordinator: ()) {
        webView.onFocused = nil
    }
}
