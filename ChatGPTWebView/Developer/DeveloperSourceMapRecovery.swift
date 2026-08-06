import Foundation

struct DeveloperSourceMapRecoveryResult: Sendable {
    let mapFiles: [DeveloperSourceFile]
    let originalSourceFiles: [DeveloperSourceFile]

    var retainedCount: Int {
        mapFiles.count + originalSourceFiles.count
    }
}
