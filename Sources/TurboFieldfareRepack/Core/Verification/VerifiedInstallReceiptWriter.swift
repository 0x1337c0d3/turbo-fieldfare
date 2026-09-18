import Foundation

enum VerifiedInstallReceiptWriter {
    static let fileName = "verified-install.json"

    struct SourceComponent {
        let role: String
        let repoID: String
        let revision: String
        let indexSHA256: String
    }

    static func encode(outputDir: String,
                              manifestSha256: String,
                              manifestSize: UInt64,
                              sourceRepoID: String?,
                              sourceRevision: String?,
                              sourceComponents: [SourceComponent] = [],
                              toolVersion: String = "TurboFieldfareRepack",
                              files: [RepackAudit.OutputFile]) throws -> Data {
        var filesDict: [String: Any] = [:]
        for file in files {
            filesDict[file.relativePath] = [
                "size": file.size,
                "sha256": file.sha256
            ]
        }
        filesDict["manifest.json"] = [
            "size": manifestSize,
            "sha256": manifestSha256
        ]

        var receipt: [String: Any] = [
            "schemaVersion": 1,
            "manifestSha256": manifestSha256,
            "modelDirectoryPath": URL(fileURLWithPath: outputDir).standardizedFileURL.path,
            "verificationTimestamp": ISO8601DateFormatter().string(from: Date()),
            "toolVersion": toolVersion,
            "files": filesDict
        ]
        if let sourceRepoID {
            receipt["sourceRepoID"] = sourceRepoID
        }
        if let sourceRevision {
            receipt["sourceRevision"] = sourceRevision
        }
        if !sourceComponents.isEmpty {
            receipt["sourceComponents"] = sourceComponents.map {
                [
                    "role": $0.role,
                    "repoID": $0.repoID,
                    "revision": $0.revision,
                    "indexSHA256": $0.indexSHA256,
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: receipt,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
