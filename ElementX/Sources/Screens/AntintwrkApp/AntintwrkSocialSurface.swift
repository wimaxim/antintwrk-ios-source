// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import WebKit

@MainActor
@Observable
final class AntintwrkSocialSurface: NSObject, WKNavigationDelegate, WKUIDelegate {
    let client: AntintwrkSocialClient
    let origin: AntintwrkClientConfiguration.SocialOrigin
    let language: String
    var profileIdentity: String?
    var selected = 0
    var messenger = false
    var keyboardVisible = false
    var loading = true
    var failed = false
    var secondary: WKWebView?
    var legalOnly = false
    var returnToMessenger = false
    private var incomingShare: AntintwrkIncomingShare?
    var invalidated = false
    var messengerDestination: AntintwrkSocialWebPolicy.MessengerDestination?
    private(set) var pages: [WKWebView] = []
    var beforeNavigation: ((String) -> Bool)?
    var onStoreRequest: (([String: Any]) async throws -> [String: Any])?
    private var documentEpochs: [ObjectIdentifier: UUID] = [:]
    private var lastUserGesture: [ObjectIdentifier: TimeInterval] = [:]
    var onShareFailure: (() -> Void)?
    var onNavigationFailure: (() -> Void)?
    var protectedInput = Set<ObjectIdentifier>()
    private var ready: Set<Int> = []
    private var retryCounts: [ObjectIdentifier: Int] = [:]
    private var safeReload: [ObjectIdentifier: Bool] = [:]
    private var policy: AntintwrkSocialWebPolicy {
        .init(origin: origin, configuration: client.configuration)
    }
    
    private let paths = ["hero-feed", "communities", "profile"]
    var active: WKWebView {
        secondary ?? pages[selected]
    }
    
    init(client: AntintwrkSocialClient, origin: AntintwrkClientConfiguration.SocialOrigin, language: String, loadInitially: Bool = true, legalOnly: Bool = false) {
        self.client = client; self.origin = origin; self.language = language; self.legalOnly = legalOnly
        super.init()
        pages = paths.map { _ in makeWebView() }
        if loadInitially {
            pages[0].load(URLRequest(url: rootURL(0)))
        }
    }
    
    func select(_ index: Int) {
        guard !invalidated, beforeNavigation?(paths[index]) != true else { return }
        secondary?.stopLoading(); secondary = nil
        selected = index
        let root = rootURL(index)
        if pages[index].url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            loading = true; failed = false; pages[index].load(URLRequest(url: root))
        } else {
            loading = !ready.contains(index)
        }
    }
    
    func open(_ route: String) {
        guard !invalidated, beforeNavigation?(route) != true else { return }
        let url = URL(string: origin.rawValue + "/\(language)/\(route)?app=1")!
        guard policy.embeddedURL(url) != nil else { return }
        secondary?.stopLoading()
        let view = makeWebView()
        secondary = view; loading = true; failed = false
        view.load(URLRequest(url: url))
    }
    
    func openShare(_ payload: AntintwrkIncomingShare) {
        guard !invalidated else { return }
        var components = URLComponents(url: rootURL(0), resolvingAgainstBaseURL: false)!
        components.path = "/\(language)/hero-compose"
        components.queryItems = [.init(name: "app", value: "1"), .init(name: "nativeShare", value: payload.id)]
        guard let url = components.url else { return }
        incomingShare = payload
        let view = makeWebView()
        secondary?.stopLoading(); secondary = view
        messenger = false; loading = true; failed = false
        view.load(URLRequest(url: url))
    }
    
    func openGame() {
        let url = URL(string: origin.rawValue + "/\(language)/goto?to=/\(language)/")!
        openExternal(url, from: active)
    }
    
    func keyboardChanged(_ notification: Notification) {
        let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        let local = active.convert(frame, from: nil)
        keyboardVisible = !active.bounds.intersection(local).isEmpty && frame.height > 20
        updateKeyboard()
    }
    
    func updateKeyboard() {
        for view in pages + (secondary.map { [$0] } ?? []) {
            view.evaluateJavaScript("window.antintwrkIme?.update(\(view === active && keyboardVisible ? "true" : "false"))")
        }
    }
    
    func invalidate() {
        invalidated = true
        for view in pages + (secondary.map { [$0] } ?? []) {
            view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil; view.loadHTMLString("", baseURL: nil)
        }
    }
    
    func rootURL(_ index: Int) -> URL {
        URL(string: origin.rawValue + "/\(language)/\(index == 2 ? profileIdentity.map { "hero/" + $0 } ?? "profile" : paths[index])?app=1")!
    }
    
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(AntintwrkWeakWebBridge(self), name: "antintwrk")
        config.userContentController.addUserScript(WKUserScript(source: "window.antintwrkNative={postMessage:(value)=>window.webkit.messageHandlers.antintwrk.postMessage(value)};document.addEventListener('click',event=>{if(event.isTrusted)window.antintwrkNative.postMessage(JSON.stringify({type:'user-gesture'}));},true);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.websiteDataStore = client.websiteDataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = !legalOnly
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        if !legalOnly, let url = Bundle.main.url(forResource: "antintwrk-profile-partner", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let source = """
        (() => {
          const tag = document.querySelector('meta[name=viewport]') || document.head.appendChild(document.createElement('meta'));
          tag.name='viewport'; tag.content='width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
          document.addEventListener('input',event=>{if(event.target instanceof HTMLElement && event.target.matches('input,textarea,[contenteditable=true]')) window.antintwrkNative?.postMessage(JSON.stringify({type:'draft'}));},{passive:true});
          const style=document.createElement('style'); style.textContent='html{-webkit-text-size-adjust:100%}'; document.head.appendChild(style);
        
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        for name in ["antintwrk-ime", "antintwrk-overlays", "antintwrk-incoming-share"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
                config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = client.configuration.socialUserAgent
        view.navigationDelegate = self; view.uiDelegate = self
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPage(_:)), for: .valueChanged)
        view.scrollView.refreshControl = refresh
        return view
    }
    
    @objc private func refreshPage(_ sender: UIRefreshControl) {
        guard let page = pages.first(where: { $0.scrollView.refreshControl === sender }) ?? secondary, !invalidated else { sender.endRefreshing(); return }
        if page === active {
            loading = true; failed = false
        }
        page.reload()
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !invalidated, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        if legalOnly {
            safeReload[ObjectIdentifier(webView)] = navigationAction.request.httpMethod == "GET"
            guard let legal = policy.legalReaderURL(url) else { decisionHandler(.cancel); return }
            if legal != url {
                decisionHandler(.cancel); webView.load(URLRequest(url: legal)); return
            }
            decisionHandler(.allow); return
        }
        if let destination = policy.messengerDestination(url) {
            guard webView === active else { decisionHandler(.cancel); return }
            messengerDestination = destination
            messenger = true
            decisionHandler(.cancel); return
        }
        guard let safe = policy.embeddedURL(url) else {
            decisionHandler(.cancel)
            if webView === active, navigationAction.navigationType == .linkActivated, ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                openExternal(url, from: webView)
            }
            return
        }
        if navigationAction.navigationType == .linkActivated, pages.contains(where: { $0 === webView }) {
            decisionHandler(.cancel)
            if let section = policy.section(safe) {
                select(section == .feed ? 0 : section == .communities ? 1 : 2)
            } else {
                secondary?.stopLoading()
                let view = makeWebView(); secondary = view; loading = true; failed = false
                view.load(URLRequest(url: safe))
            }
            return
        }
        if url != safe, navigationAction.request.httpMethod == "GET" {
            decisionHandler(.cancel); webView.load(URLRequest(url: safe)); return
        }
        if webView === active {
            loading = true; failed = false
        }
        safeReload[ObjectIdentifier(webView)] = navigationAction.request.httpMethod == "GET"
        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard !invalidated else { decisionHandler(.cancel); return }
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode == 429 || (500...599).contains(response.statusCode) {
            decisionHandler(.cancel)
            handleFailure(webView, error: URLError(.badServerResponse))
            return
        }
        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        documentEpochs[ObjectIdentifier(webView)] = UUID()
        lastUserGesture.removeValue(forKey: ObjectIdentifier(webView))
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !invalidated else { return }
        protectedInput.remove(ObjectIdentifier(webView))
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !invalidated else { return }
        if legalOnly {
            Task { [weak self, weak webView] in
                guard let self, let webView else { return }
                let maintenance = try? await webView.evaluateJavaScript("/^Just a moment(?:\\.\\.\\.|…)?$/i.test(document.title.trim())||Array.from(document.querySelectorAll('h1,h2')).some(e=>/^(just a moment[.!… ]*|maintenance works)$/i.test(e.textContent.trim()))")
                guard !invalidated else { return }
                if maintenance as? Bool == true {
                    handleFailure(webView, error: URLError(.badServerResponse))
                } else {
                    finishLoading(webView)
                }
            }
        } else {
            finishLoading(webView)
        }
    }
    
    private func finishLoading(_ webView: WKWebView) {
        webView.scrollView.refreshControl?.endRefreshing()
        retryCounts[ObjectIdentifier(webView)] = 0
        webView.evaluateJavaScript("window.antintwrkIme?.update(\(webView === active && keyboardVisible ? "true" : "false"))")
        if let index = pages.firstIndex(where: { $0 === webView }) {
            ready.insert(index)
        }
        if webView === active {
            loading = false; failed = false
            if let incomingShare, webView.url?.path == "/\(language)/hero-compose",
               URLComponents(url: webView.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "nativeShare" })?.value == incomingShare.id,
               let script = incomingShare.script {
                Task { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    let result = try? await webView.callAsyncJavaScript("return await " + script, arguments: [:], in: nil, contentWorld: .page)
                    guard !invalidated, webView === active, self.incomingShare?.id == incomingShare.id else { return }
                    if result as? String == "ok" {
                        self.incomingShare = nil
                    } else {
                        onShareFailure?()
                    }
                }
            }
        }
        if !legalOnly, webView === pages[0] {
            // Warm retained roots only after the initial feed has completed; never replace its document.
            for index in 1...2 where pages[index].url == nil {
                pages[index].load(URLRequest(url: rootURL(index)))
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(webView, error: error)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(webView, error: error)
    }
    
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handleFailure(webView, error: URLError(.networkConnectionLost))
    }
    
    private func handleFailure(_ view: WKWebView, error: Error) {
        guard !invalidated, (error as NSError).code != NSURLErrorCancelled else { return }
        view.scrollView.refreshControl?.endRefreshing()
        let key = ObjectIdentifier(view)
        let count = retryCounts[key, default: 0]
        if count < 5, safeReload[key] == true {
            retryCounts[key] = count + 1
            Task { [weak self, weak view] in
                try? await Task.sleep(for: .seconds(min(8, 1 << count)))
                guard let self, !invalidated, let view else { return }
                view.reload()
            }
        } else if view === active {
            failed = true; loading = false
        }
    }
    
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard canPrompt(webView, frame: frame), let controller = presenter(webView) else { completionHandler(); return }
        let alert = UIAlertController(title: "ANTINTWRK", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        controller.present(alert, animated: true)
    }
    
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard canPrompt(webView, frame: frame), let controller = presenter(webView) else { completionHandler(false); return }
        let alert = UIAlertController(title: "ANTINTWRK", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AntintwrkStrings.value("screen_ant_shell_close"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        controller.present(alert, animated: true)
    }
    
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        guard canPrompt(webView, frame: frame), let controller = presenter(webView) else { completionHandler(nil); return }
        let alert = UIAlertController(title: "ANTINTWRK", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: AntintwrkStrings.value("screen_ant_shell_close"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        controller.present(alert, animated: true)
    }
    
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !invalidated, webView === active, navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return nil }
        if let safe = policy.embeddedURL(url) {
            let view = makeWebView(); secondary?.stopLoading(); secondary = view; loading = true; failed = false
            view.load(URLRequest(url: safe))
        } else if ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
            openExternal(url, from: webView)
        }
        return nil
    }
    
    private func openExternal(_ url: URL, from view: WKWebView) {
        if url.host == URL(string: origin.rawValue)?.host, url.path.split(separator: "/").contains(where: { ["go", "goto", "go.html"].contains(String($0)) }) {
            let document = view.url
            loading = true
            Task { [weak self, weak view] in
                guard let self, let view else { return }
                do {
                    let target = try await client.externalDestination(url, origin: origin)
                    guard !invalidated, view === active, view.url == document else { return }
                    loading = false
                    await UIApplication.shared.open(target)
                } catch {
                    guard !invalidated, view === active, view.url == document else { return }
                    loading = false; onNavigationFailure?()
                }
            }
        } else {
            UIApplication.shared.open(url)
        }
    }
    
    func receive(_ message: WKScriptMessage) {
        guard !invalidated, message.frameInfo.isMainFrame, let view = message.webView, view === active,
              message.frameInfo.securityOrigin.host == URL(string: origin.rawValue)?.host,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.request.url.flatMap(policy.embeddedURL) != nil,
              message.frameInfo.request.url.flatMap(policy.embeddedURL) == view.url.flatMap(policy.embeddedURL),
              let body = message.body as? String, body.utf8.count <= 200_000,
              let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "download" || body.utf8.count <= 2048 else { return }
        if type == "user-gesture" {
            lastUserGesture[ObjectIdentifier(view)] = ProcessInfo.processInfo.systemUptime; return
        }
        if type == "draft" {
            protectedInput.insert(ObjectIdentifier(view)); return
        }
        if type == "editor", json["active"] as? Bool == true {
            protectedInput.insert(ObjectIdentifier(view)); return
        }
        guard let id = json["id"] as? String, id.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return }
        let original = view.url
        let documentEpoch = documentEpochs[ObjectIdentifier(view)]
        let replyJSON: ([String: Any]) -> Void = { [weak self, weak view] payload in
            guard let self, !invalidated, let view, view === active, view.url == original,
                  documentEpochs[ObjectIdentifier(view)] == documentEpoch,
                  let result = try? JSONSerialization.data(withJSONObject: payload.merging(["id": id]) { _, value in value }), let text = String(data: result, encoding: .utf8) else { return }
            view.evaluateJavaScript("window.antintwrkNative.onmessage?.({data:JSON.stringify(\(text))})")
        }
        let reply: (Bool) -> Void = { replyJSON(["ok": $0]) }
        if ["store-catalog", "store-purchase", "store-restore"].contains(type) {
            guard !legalOnly, let handler = onStoreRequest,
                  type == "store-catalog" || ProcessInfo.processInfo.systemUptime - (lastUserGesture[ObjectIdentifier(view)] ?? -.infinity) <= 120 else {
                replyJSON(["ok": false, "error": "STORE_UNAVAILABLE"]); return
            }
            Task {
                do {
                    var response = try await handler(json)
                    if response["ok"] == nil {
                        response["ok"] = true
                    }
                    replyJSON(response)
                } catch {
                    replyJSON(["ok": false, "error": "STORE_UNAVAILABLE"])
                }
            }
        } else if type == "open-external" {
            guard !legalOnly, let text = json["url"] as? String, let target = policy.assistanceURL(text) ?? policy.appleBillingURL(text),
                  ProcessInfo.processInfo.systemUptime - (lastUserGesture[ObjectIdentifier(view)] ?? -.infinity) <= 30 else { reply(false); return }
            Task { await reply(UIApplication.shared.open(target)) }
        } else if type == "copy", let text = json["text"] as? String, text.count <= 1800 {
            UIPasteboard.general.string = publicText(text); reply(true)
        } else if type == "share", let text = json["url"] as? String, let url = URL(string: text), ["https", "http"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
                  let controller = presenter(view) {
            let activity = UIActivityViewController(activityItems: [publicText(text)], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = view
            activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            controller.present(activity, animated: true); reply(true)
        } else {
            reply(false)
        }
    }
    
    func notifyStoreUpdated() {
        guard !invalidated, !legalOnly else { return }
        for view in pages + (secondary.map { [$0] } ?? []) {
            view.evaluateJavaScript("window.dispatchEvent(new Event('antintwrk-store-updated'))")
        }
    }
    
    private func publicText(_ text: String) -> String {
        guard var components = URLComponents(string: text), components.scheme == "https", ["antimsg.com", "antintwrk.com"].contains(components.host ?? "") else { return text }
        let secrets: Set = ["app", "app_ref", "native_legal", "token", "csrf", "ticket", "code", "access_token", "id_token", "refresh_token", "state", "session"]
        components.host = "antintwrk.com"
        components.queryItems = components.queryItems?.filter { !secrets.contains($0.name) }
        return components.url?.absoluteString ?? "https://antintwrk.com"
    }
    
    private func canPrompt(_ view: WKWebView, frame: WKFrameInfo) -> Bool {
        !invalidated && view === active && frame.isMainFrame && frame.request.url.flatMap(policy.embeddedURL) != nil
    }
    
    private func presenter(_ view: WKWebView) -> UIViewController? {
        var controller = view.window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

struct AntintwrkWebContainer: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        view
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

struct AntintwrkSocialScreen: View {
    @Bindable var surface: AntintwrkSocialSurface
    @Bindable var model: AntintwrkAppModel
    let logout: () -> Void
    let signIn: AnyView
    private let keys = ["screen_ant_shell_feed", "screen_ant_shell_communities", "screen_ant_shell_profile"]
    private let icons = ["house", "person.2", "person.crop.circle"]
    
    private var primaryNavigation: some View {
        HStack(spacing: 12) {
            Button(AntintwrkStrings.value("screen_ant_shell_social")) { surface.messenger = false }.tint(surface.messenger ? .gray : .orange)
            Spacer()
            Button { model.messenger?.showChats(); surface.messenger = true } label: {
                HStack(spacing: 6) {
                    Text(AntintwrkStrings.value("screen_ant_shell_messenger"))
                    if model.unreadCount > 0 {
                        Text(model.unreadCount > 99 ? "99+" : String(model.unreadCount))
                            .font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                            .foregroundStyle(.white).background(.orange, in: Capsule())
                    }
                }
            }.accessibilityValue(String(model.unreadCount)).tint(surface.messenger ? .orange : .gray)
            Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(L10n.commonSettings)
        }.padding()
    }
    
    @ViewBuilder private var socialActions: some View {
        if !surface.messenger, !model.needsSocialLogin {
            HStack(spacing: 24) {
                Spacer()
                Button { surface.open("people") } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel(AntintwrkStrings.value("screen_ant_menu_people"))
                Button { surface.open("notifications") } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell")
                        if model.notificationsCount > 0 {
                            Text(model.notificationsCount > 99 ? "99+" : String(model.notificationsCount)).font(.caption.bold())
                        }
                    }
                }.accessibilityLabel(L10n.screenNotificationSettingsTitle).accessibilityValue(String(model.notificationsCount))
                Menu {
                    Button(L10n.actionCreate) { surface.open("hero-compose") }
                    Button(AntintwrkStrings.value("screen_ant_menu_people")) { surface.open("people") }
                    Button(AntintwrkStrings.value("screen_ant_menu_monetization")) { surface.open("monetization") }
                    Button(L10n.commonSettings) { model.openSettings() }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(AntintwrkStrings.value("screen_ant_menu_more"))
            }.padding(.horizontal).padding(.bottom, 12)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            primaryNavigation
            socialActions
            if !surface.messenger, surface.secondary != nil {
                HStack(spacing: 12) { Button(AntintwrkStrings.value("screen_antintwrk_back")) { surface.secondary?.stopLoading(); surface.secondary = nil; surface.loading = false
                    if surface.returnToMessenger {
                        surface.messenger = true; surface.returnToMessenger = false
                    }
                }; Spacer() }.padding(.horizontal)
            }
            ZStack(alignment: .top) {
                ForEach(Array(surface.pages.enumerated()), id: \.offset) { index, view in
                    AntintwrkWebContainer(view: view)
                        .opacity(!surface.messenger && !model.needsSocialLogin && surface.secondary == nil && surface.selected == index ? 1 : 0)
                        .allowsHitTesting(!surface.messenger && !model.needsSocialLogin && surface.secondary == nil && surface.selected == index)
                        .accessibilityHidden(surface.messenger || model.needsSocialLogin || surface.secondary != nil || surface.selected != index)
                }
                if let secondary = surface.secondary {
                    AntintwrkWebContainer(view: secondary).id(ObjectIdentifier(secondary))
                        .opacity(surface.messenger || model.needsSocialLogin ? 0 : 1).allowsHitTesting(!surface.messenger && !model.needsSocialLogin).accessibilityHidden(surface.messenger || model.needsSocialLogin)
                }
                if !surface.messenger, model.needsSocialLogin {
                    signIn
                }
                if surface.messenger {
                    if let messenger = model.messenger {
                        messenger.navigation.toPresentable()
                    } else if model.messengerFailed {
                        VStack(spacing: 12) { Text(AntintwrkStrings.value("screen_ant_messenger_unavailable")); Button(AntintwrkStrings.value("screen_ant_web_retry")) { model.retryMessenger() } }.padding()
                    } else {
                        AntintwrkWelcomeScreen(context: model.loading.context)
                    }
                }
                if surface.loading, !surface.messenger {
                    ProgressView().padding(8).background(.ultraThinMaterial, in: Capsule())
                }
                if surface.failed, !surface.messenger {
                    VStack(spacing: 12) {
                        Text(AntintwrkStrings.value("screen_ant_social_unavailable"))
                        Button(AntintwrkStrings.value("screen_ant_web_retry")) { surface.failed = false; surface.loading = true; surface.active.reload() }
                    }.padding().background(.regularMaterial).frame(maxHeight: .infinity)
                }
            }
            if !surface.keyboardVisible, !surface.messenger, !model.needsSocialLogin {
                HStack(spacing: 12) {
                    ForEach(0..<3) { index in
                        Button { surface.select(index) } label: {
                            VStack(spacing: 8) {
                                if index == 2, let image = model.profileImage {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 26, height: 26).clipShape(Circle())
                                } else {
                                    Image(systemName: icons[index]).frame(height: 26)
                                }
                                Text(AntintwrkStrings.value(keys[index])).font(.caption)
                            }.frame(maxWidth: .infinity)
                        }.tint(index == surface.selected ? .orange : .gray)
                    }
                }.padding(12)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { surface.keyboardChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in surface.keyboardVisible = false; surface.updateKeyboard() }
        .alert("ANTINTWRK", isPresented: Binding(get: { model.error != nil }, set: {
            if !$0 {
                model.error = nil
            }
        })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: surface.messengerDestination) { _, destination in
            if let destination {
                model.openMessenger(destination)
            }
        }
    }
}

struct AntintwrkLegalWebScreen: View {
    @State private var surface: AntintwrkSocialSurface
    init(client: AntintwrkSocialClient, url: URL) {
        let surface = AntintwrkSocialSurface(client: client, origin: .russian, language: url.path.split(separator: "/").first.map(String.init) ?? "en", loadInitially: false, legalOnly: true)
        surface.legalOnly = true
        surface.pages[0].stopLoading()
        surface.pages[0].load(URLRequest(url: url))
        _surface = State(initialValue: surface)
    }
    
    var body: some View {
        ZStack {
            AntintwrkWebContainer(view: surface.pages[0])
            if surface.loading {
                ProgressView()
            }
            if surface.failed {
                VStack(spacing: 16) {
                    Text(AntintwrkStrings.value("screen_ant_social_unavailable")).multilineTextAlignment(.center)
                    Button(AntintwrkStrings.value("screen_ant_web_retry")) { surface.failed = false; surface.loading = true; surface.pages[0].reload() }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
            }
        }.onDisappear { surface.invalidate() }
    }
}

@MainActor
private final class AntintwrkWeakWebBridge: NSObject, WKScriptMessageHandler {
    private weak var surface: AntintwrkSocialSurface?
    init(_ surface: AntintwrkSocialSurface) {
        self.surface = surface
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        surface?.receive(message)
    }
}
