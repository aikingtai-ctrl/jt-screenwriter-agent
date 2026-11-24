import Network
import UIKit
import WebKit

private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class WorkbenchViewController: UIViewController {
    private let workbenchURL = URL(string: "https://aikingtai-ctrl.github.io/jt-screenwriter-agent/")!
    private let allowedInAppHosts: Set<String> = [
        "aikingtai-ctrl.github.io",
        "ddzxsafkrwetdzhwlzxm.supabase.co",
    ]

    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let refreshControl = UIRefreshControl()
    private let offlineCard = UIView()
    private let offlineLabel = UILabel()
    private var progressObserver: NSKeyValueObservation?
    private let pathMonitor = NWPathMonitor()
    private var hasNetwork = true

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        view.backgroundColor = .white

        configureWebView()
        configureProgressBar()
        configureOfflineOverlay()
        startNetworkMonitor()
        loadWorkbench()
    }

    deinit {
        progressObserver?.invalidate()
        pathMonitor.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "jtiOS")
    }

    private func configureWebView() {
        let controller = WKUserContentController()
        let bridgeScript = """
        (function() {
          try { document.documentElement.classList.add('jt-native-ios'); } catch (e) {}
          window.JTiOS = {
            platform: 'ios',
            copyText: function(txt) {
              try { window.webkit.messageHandlers.jtiOS.postMessage({ action: 'copyText', text: String(txt || '') }); } catch (e) {}
            },
            shareText: function(title, text) {
              try { window.webkit.messageHandlers.jtiOS.postMessage({ action: 'shareText', title: String(title || 'JT 编剧台'), text: String(text || '') }); } catch (e) {}
            },
            haptic: function(kind) {
              try { window.webkit.messageHandlers.jtiOS.postMessage({ action: 'haptic', kind: String(kind || 'light') }); } catch (e) {}
            },
            toast: function(msg) {
              try { window.webkit.messageHandlers.jtiOS.postMessage({ action: 'toast', text: String(msg || '') }); } catch (e) {}
            }
          };
        })();
        """
        controller.addUserScript(
            WKUserScript(source: bridgeJSOrFallback(bridgeScript), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        controller.add(WeakScriptMessageProxy(delegate: self), name: "jtiOS")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.backgroundColor = .white
        webView.isOpaque = true
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) JTScreenwriteriOS/1.3.0"

        refreshControl.tintColor = UIColor(red: 0, green: 113.0 / 255.0, blue: 227.0 / 255.0, alpha: 1)
        refreshControl.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            guard let self = self else { return }
            let p = Float(view.estimatedProgress)
            self.progressView.isHidden = p >= 1.0
            self.progressView.setProgress(p, animated: true)
        }
    }

    private func bridgeJSOrFallback(_ src: String) -> String {
        return src
    }

    private func configureProgressBar() {
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        progressView.progressTintColor = UIColor(red: 0, green: 113.0 / 255.0, blue: 227.0 / 255.0, alpha: 1)
        progressView.isHidden = true
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    private func configureOfflineOverlay() {
        offlineCard.translatesAutoresizingMaskIntoConstraints = false
        offlineCard.backgroundColor = .white
        offlineCard.isHidden = true

        offlineLabel.translatesAutoresizingMaskIntoConstraints = false
        offlineLabel.text = "当前网络不可用，请检查 Wi-Fi 或蜂窝网络后重试。"
        offlineLabel.textAlignment = .center
        offlineLabel.numberOfLines = 0
        offlineLabel.font = .systemFont(ofSize: 17, weight: .medium)
        offlineLabel.textColor = UIColor(red: 29.0 / 255.0, green: 29.0 / 255.0, blue: 31.0 / 255.0, alpha: 1)

        var btnCfg = UIButton.Configuration.filled()
        btnCfg.title = "重新连接"
        btnCfg.cornerStyle = .capsule
        btnCfg.baseBackgroundColor = UIColor(red: 0, green: 113.0 / 255.0, blue: 227.0 / 255.0, alpha: 1)
        btnCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        let retryBtn = UIButton(configuration: btnCfg, primaryAction: UIAction { [weak self] _ in
            self?.retryConnection()
        })
        retryBtn.translatesAutoresizingMaskIntoConstraints = false

        offlineCard.addSubview(offlineLabel)
        offlineCard.addSubview(retryBtn)
        view.addSubview(offlineCard)

        NSLayoutConstraint.activate([
            offlineCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            offlineCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            offlineCard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            offlineCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            offlineLabel.centerXAnchor.constraint(equalTo: offlineCard.centerXAnchor),
            offlineLabel.centerYAnchor.constraint(equalTo: offlineCard.centerYAnchor, constant: -24),
            offlineLabel.leadingAnchor.constraint(greaterThanOrEqualTo: offlineCard.leadingAnchor, constant: 32),
            offlineLabel.trailingAnchor.constraint(lessThanOrEqualTo: offlineCard.trailingAnchor, constant: -32),
            retryBtn.topAnchor.constraint(equalTo: offlineLabel.bottomAnchor, constant: 20),
            retryBtn.centerXAnchor.constraint(equalTo: offlineCard.centerXAnchor),
        ])
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let satisfied = (path.status == .satisfied)
                let wasOffline = !self.hasNetwork
                self.hasNetwork = satisfied
                if satisfied && wasOffline && self.offlineCard.isHidden == false {
                    self.retryConnection()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.jintai.screenwriter.netmon"))
    }

    private func loadWorkbench() {
        offlineCard.isHidden = true
        let req = URLRequest(url: workbenchURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
        webView.load(req)
    }

    @objc private func handlePullToRefresh() {
        if webView.url != nil {
            webView.reload()
        } else {
            loadWorkbench()
        }
    }

    private func retryConnection() {
        offlineCard.isHidden = true
        if webView.url != nil {
            webView.reload()
        } else {
            loadWorkbench()
        }
    }

    private func triggerHaptic(_ kind: String) {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch kind {
        case "medium":
            style = .medium
        case "heavy":
            style = .heavy
        default:
            style = .light
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

extension WorkbenchViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        switch action {
        case "copyText":
            if let text = body["text"] as? String {
                UIPasteboard.general.string = text
                triggerHaptic("light")
            }
        case "shareText":
            let title = (body["title"] as? String) ?? "JT 编剧台"
            let text = (body["text"] as? String) ?? ""
            let items: [Any] = text.isEmpty ? [title] : [title, text]
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
            present(sheet, animated: true)
        case "haptic":
            triggerHaptic((body["kind"] as? String) ?? "light")
        default:
            break
        }
    }
}

extension WorkbenchViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           let host = url.host?.lowercased(),
           !allowedInAppHosts.contains(host) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        offlineCard.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        if (error as NSError).code != NSURLErrorCancelled && !hasNetwork {
            offlineCard.isHidden = false
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        if (error as NSError).code != NSURLErrorCancelled {
            offlineLabel.text = "暂时无法连接 JT 编剧台（\((error as NSError).localizedDescription)）"
            offlineCard.isHidden = false
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension WorkbenchViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if let host = url.host?.lowercased(), allowedInAppHosts.contains(host) {
                webView.load(URLRequest(url: url))
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: "JT 编剧台", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: "JT 编剧台", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: "JT 编剧台", message: prompt, preferredStyle: .alert)
        alert.addTextField { tf in tf.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}
