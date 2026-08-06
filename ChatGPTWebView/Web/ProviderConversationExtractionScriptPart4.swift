extension ProviderConversationExtractionScript {
    static let scriptPart4 = #"""
          const error = blockingChallengeDetected
            ? 'security-interstitial'
            : (extraction.error || null);
          extraction.diagnostics.challengeDetected = blockingChallengeDetected;
          return JSON.stringify({
            title,
            turns,
            sourceURL: source,
            exportedAt,
            error,
            diagnostics: extraction.diagnostics
          });
        })();
        """#
}
