import CryptoKit
import Foundation
import UIKit

struct ProviderExtractionDiagnostics: Decodable {
    let strategyVersion: Int
    let strategy: String
    let expectedCanaries: [String]
    let matchedCanaries: [String]
    let usedFallback: Bool
    let challengeDetected: Bool
    let unclassifiedCandidateCount: Int
}

struct ProviderExtractionHealthReport: Equatable {
    enum State: String {
        case healthy
        case safeDrift
        case unsafe
    }

    let providerID: AIProviderID
    let providerName: String
    let state: State
    let strategyVersion: Int
    let strategy: String
    let matchedCanaries: [String]
    let missingCanaries: [String]
    let usedFallback: Bool
    let challengeDetected: Bool
    let unclassifiedCandidateCount: Int
    let userTurnCount: Int
    let assistantTurnCount: Int
    let signature: String

    var shouldAlert: Bool {
        state != .healthy
    }

    var diagnosticCaptureRecommended: Bool {
        shouldAlert
    }

    var alertTitle: String {
        switch state {
        case .healthy:
            return "\(providerName) UI Healthy"
        case .safeDrift:
            return "\(providerName) UI Change Detected"
        case .unsafe:
            return "\(providerName) Context Capture Blocked"
        }
    }

    var alertMessage: String {
        let missing = missingCanaries.isEmpty
            ? "None"
            : missingCanaries.joined(separator: ", ")

        switch state {
        case .healthy:
            return "ContextPort matched the expected \(providerName) conversation structure."
        case .safeDrift:
            return "ContextPort detected a change in \(providerName)'s conversation UI. Context was still verified using a safe fallback and can be saved. Missing UI markers: \(missing). This alert is shown once for this drift signature. Enable Developer Mode to capture the loaded sources for selector review."
        case .unsafe:
            if challengeDetected {
                return "ContextPort detected a blocking security or bot-check interstitial instead of a safely readable \(providerName) conversation. Nothing was saved. This alert is shown once for this drift signature. Enable Developer Mode to capture the loaded sources after returning to the conversation."
            }
            return "ContextPort could not positively identify both user and \(providerName) turns after the provider UI contract changed. Nothing was saved. Missing UI markers: \(missing). This alert is shown once for this drift signature. Enable Developer Mode to capture the loaded sources for selector review."
        }
    }

    var failureDescription: String {
        if challengeDetected {
            return "ContextPort detected a security or bot-check interstitial instead of a readable conversation. Complete the check, return to the conversation, and try Save Context again."
        }

        let missing = missingCanaries.isEmpty
            ? "the expected conversation role evidence"
            : missingCanaries.joined(separator: ", ")
        return "\(providerName)'s conversation UI appears to have changed. ContextPort could not safely identify both user and AI turns. Missing UI markers: \(missing). Nothing was saved."
    }
}

struct ProviderExtractionHealthMonitor {
    private static let alertedSignaturesKey = "ProviderExtractionHealthAlertedSignaturesV1"
    private static let maximumRememberedSignatures = 64

    static func evaluate(
        provider: AIProvider,
        diagnostics: ProviderExtractionDiagnostics,
        userTurnCount: Int,
        assistantTurnCount: Int
    ) -> ProviderExtractionHealthReport {
        let expected = Set(diagnostics.expectedCanaries)
        let matched = Set(diagnostics.matchedCanaries)
        let missing = expected.subtracting(matched).sorted()
        let normalizedMatched = matched.sorted()

        let state: ProviderExtractionHealthReport.State
        if diagnostics.challengeDetected || userTurnCount == 0 || assistantTurnCount == 0 {
            state = .unsafe
        } else if diagnostics.usedFallback || !missing.isEmpty {
            state = .safeDrift
        } else {
            state = .healthy
        }

        let signatureMaterial = [
            provider.id.rawValue,
            String(diagnostics.strategyVersion),
            diagnostics.strategy,
            "state=\(state.rawValue)",
            "missing=\(missing.joined(separator: ","))",
            "fallback=\(diagnostics.usedFallback)",
            "challenge=\(diagnostics.challengeDetected)",
            "unclassified=\(diagnostics.unclassifiedCandidateCount > 0)"
        ].joined(separator: "|")

        let signatureDigest = SHA256.hash(data: Data(signatureMaterial.utf8))
        let signature = signatureDigest.map { String(format: "%02x", $0) }.joined()

        return ProviderExtractionHealthReport(
            providerID: provider.id,
            providerName: provider.displayName,
            state: state,
            strategyVersion: diagnostics.strategyVersion,
            strategy: diagnostics.strategy,
            matchedCanaries: normalizedMatched,
            missingCanaries: missing,
            usedFallback: diagnostics.usedFallback,
            challengeDetected: diagnostics.challengeDetected,
            unclassifiedCandidateCount: diagnostics.unclassifiedCandidateCount,
            userTurnCount: userTurnCount,
            assistantTurnCount: assistantTurnCount,
            signature: signature
        )
    }

    static func shouldPresentAlert(
        for report: ProviderExtractionHealthReport,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard report.shouldAlert else { return false }
        let signatures = userDefaults.stringArray(forKey: alertedSignaturesKey) ?? []
        return !signatures.contains(report.signature)
    }

    static func markAlertPresented(
        for report: ProviderExtractionHealthReport,
        userDefaults: UserDefaults = .standard
    ) {
        var signatures = userDefaults.stringArray(forKey: alertedSignaturesKey) ?? []
        signatures.removeAll { $0 == report.signature }
        signatures.append(report.signature)
        if signatures.count > maximumRememberedSignatures {
            signatures.removeFirst(signatures.count - maximumRememberedSignatures)
        }
        userDefaults.set(signatures, forKey: alertedSignaturesKey)
    }
}

@MainActor
enum ProviderExtractionHealthAlertPresenter {
    static func presentIfNeeded(_ report: ProviderExtractionHealthReport) {
        guard ProviderExtractionHealthMonitor.shouldPresentAlert(for: report),
              let presenter = topViewController() else {
            return
        }

        let alert = UIAlertController(
            title: report.alertTitle,
            message: report.alertMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))

        if report.diagnosticCaptureRecommended {
            alert.addAction(UIAlertAction(title: "Enable Dev Capture", style: .default) { _ in
                UserDefaults.standard.set(true, forKey: "developerModeEnabled")
                DispatchQueue.main.async {
                    presentDeveloperModeInstructions()
                }
            })
        }

        ProviderExtractionHealthMonitor.markAlertPresented(for: report)
        presenter.present(alert, animated: true)
    }

    private static func presentDeveloperModeInstructions() {
        guard let presenter = topViewController() else { return }
        let alert = UIAlertController(
            title: "Developer Mode Enabled",
            message: "Open the Dev tab, refresh Sources if needed, then tap Save Sources to Memory. The ZIP will contain the provider's loaded shipped UI files for selector review.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        topViewController(from: activeWindowRootViewController())
    }

    private static func topViewController(
        from base: UIViewController?
    ) -> UIViewController? {
        if let navigationController = base as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController)
        }
        if let tabBarController = base as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return topViewController(from: selectedViewController)
        }
        if let presentedViewController = base?.presentedViewController {
            return topViewController(from: presentedViewController)
        }
        return base
    }

    private static func activeWindowRootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        return activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? activeScene?.windows.first?.rootViewController
    }
}
