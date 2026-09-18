import Foundation
import Synchronization
import Testing

@testable import TurboFieldfareRepackCore

extension RemotePayloadCopyTests {
  @Test func sharedExpertSourceRejectsAnUnexpectedIndexFingerprint() async throws {
    let primaryDirectory = tmpDirForRemote("hybrid-fingerprint-primary")
    let supplementalDirectory = tmpDirForRemote("hybrid-fingerprint-shared8")
    let output = tmpPathForRemote("hybrid-fingerprint-output")
    defer { cleanUpRemote([primaryDirectory, supplementalDirectory, output]) }
    let primary = try SyntheticSnapshot.build(
      at: primaryDirectory, seed: 0x3333, sharedExpertBits: 4)
    let supplemental = try SyntheticSnapshot.build(
      at: supplementalDirectory, seed: 0x4444, sharedExpertBits: 8)

    resetFakeHF()
    FakeHFURLProtocol.files = try remoteFiles(
      snapshotDir: primaryDirectory,
      snap: primary,
      includeRequiredTokenizer: true,
      includeOptionalTokenizer: false)
    let supplementalFiles = try remoteFiles(
      snapshotDir: supplementalDirectory,
      snap: supplemental,
      includeRequiredTokenizer: false,
      includeOptionalTokenizer: false)
    for (filename, data) in supplementalFiles {
      FakeHFURLProtocol.files["aux/model::" + filename] = data
    }
    let base = remoteOptions(outputDir: output, session: fakeHFSession())
    let options = RemoteStreamingRepackOptions(
      repoID: base.repoID,
      revision: base.revision,
      outputDir: base.outputDir,
      token: base.token,
      requireKnownSource: base.requireKnownSource,
      rangeChunkBytes: base.rangeChunkBytes,
      writeTileBytes: base.writeTileBytes,
      minFreeReserveBytes: base.minFreeReserveBytes,
      overwrite: base.overwrite,
      resume: base.resume,
      downloadSession: base.downloadSession,
      baseURL: base.baseURL,
      rangeRetryAttempts: base.rangeRetryAttempts,
      retryBaseDelayNs: base.retryBaseDelayNs,
      sharedExpertSource: RemoteSupplementalSource(
        repoID: "aux/model",
        revision: FakeHFURLProtocol.commit,
        sourceIndexSHA256: String(repeating: "0", count: 64),
        namespace: "shared8"))

    await #expect(throws: RepackError.self) {
      _ = try await RemoteStreamingRepacker(options: options).run()
    }
    #expect(!FileManager.default.fileExists(atPath: output))
  }

  @Test func remotePayloadCopyCanSourceOnlySharedExpertsFromEightBitSnapshot() async throws {
    let primaryDirectory = tmpDirForRemote("hybrid-primary")
    let supplementalDirectory = tmpDirForRemote("hybrid-shared8")
    let output = tmpPathForRemote("hybrid-output")
    defer { cleanUpRemote([primaryDirectory, supplementalDirectory, output]) }
    let primary = try SyntheticSnapshot.build(
      at: primaryDirectory, seed: 0x1111, sharedExpertBits: 4)
    let supplemental = try SyntheticSnapshot.build(
      at: supplementalDirectory, seed: 0x2222, sharedExpertBits: 8)

    resetFakeHF()
    FakeHFURLProtocol.files = try remoteFiles(
      snapshotDir: primaryDirectory,
      snap: primary,
      includeRequiredTokenizer: true,
      includeOptionalTokenizer: false)
    let supplementalFiles = try remoteFiles(
      snapshotDir: supplementalDirectory,
      snap: supplemental,
      includeRequiredTokenizer: false,
      includeOptionalTokenizer: false)
    for (filename, data) in supplementalFiles {
      FakeHFURLProtocol.files["aux/model::" + filename] = data
    }
    let supplementalMetadata = try IndexLoader.load(snapshotDir: supplementalDirectory)
    let source = RemoteSupplementalSource(
      repoID: "aux/model",
      revision: FakeHFURLProtocol.commit,
      sourceIndexSHA256: supplementalMetadata.indexSha256Hex,
      namespace: "shared8")
    let base = remoteOptions(outputDir: output, session: fakeHFSession())
    let options = RemoteStreamingRepackOptions(
      repoID: base.repoID,
      revision: base.revision,
      outputDir: base.outputDir,
      token: base.token,
      requireKnownSource: base.requireKnownSource,
      rangeChunkBytes: base.rangeChunkBytes,
      writeTileBytes: base.writeTileBytes,
      minFreeReserveBytes: base.minFreeReserveBytes,
      overwrite: base.overwrite,
      resume: base.resume,
      downloadSession: base.downloadSession,
      baseURL: base.baseURL,
      rangeRetryAttempts: base.rangeRetryAttempts,
      retryBaseDelayNs: base.retryBaseDelayNs,
      sharedExpertSource: source)

    let result = try await RemoteStreamingRepacker(options: options).run()
    #expect(result.plan.resident.entries
      .filter { $0.name.contains(".mlp.") }
      .allSatisfy { $0.quantSpec?.bits == 8 })
    #expect(result.plan.resident.entries
      .filter { $0.quantSpec != nil && !$0.name.contains(".mlp.") }
      .allSatisfy { !$0.sourceWeight.shardPath.hasPrefix("shared8/") })
    let manifestData = try Data(contentsOf: URL(fileURLWithPath:
      (output as NSString).appendingPathComponent("manifest.json")))
    let manifest = try #require(
      JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    let quant = try #require(manifest["quant"] as? [String: Any])
    let shared = try #require(quant["sharedExpert"] as? [String: Any])
    #expect(shared["weightBits"] as? Int == 8)
    #expect(manifest["modelID"] as? String
      == "turbofieldfare/gemma-4-26b-a4b-it-4bit-shared8")
    let receiptData = try Data(contentsOf: URL(fileURLWithPath:
      (output as NSString).appendingPathComponent("verified-install.json")))
    let receipt = try #require(
      JSONSerialization.jsonObject(with: receiptData) as? [String: Any])
    let components = try #require(receipt["sourceComponents"] as? [[String: Any]])
    #expect(components.count == 2)
    #expect(components.contains { $0["role"] as? String == "sharedExpert"
      && $0["repoID"] as? String == "aux/model" })
  }

  @Test func remotePayloadCopyCompletes() async throws {
    let snapshotDir = tmpDirForRemote("snap")
    let remoteOutput = tmpPathForRemote("remote")
    defer { cleanUpRemote([snapshotDir, remoteOutput]) }
    let snapshot = try SyntheticSnapshot.build(
      at: snapshotDir,
      seed: 0x1020_3040_5060_7080)

    resetFakeHF()
    FakeHFURLProtocol.files = try remoteFiles(
      snapshotDir: snapshotDir,
      snap: snapshot,
      includeRequiredTokenizer: true,
      includeOptionalTokenizer: true)
    let recorder = InstallProgressRecorder()

    let result = try await RemoteStreamingRepacker(
      options: remoteOptions(
        outputDir: remoteOutput,
        session: fakeHFSession())
    ).run { recorder.append($0) }

    #expect(result.reusedBytes == 0)
    #expect(result.downloadedThisRunBytes == result.remoteBytesToDownload)
    for relativePath in [
      "model_weights.bin",
      "packed_experts/layout.json",
      "packed_experts/layer_00.bin",
      "packed_experts/layer_01.bin",
      "manifest.json",
    ] {
      let remote = (remoteOutput as NSString).appendingPathComponent(relativePath)
      #expect(FileManager.default.fileExists(atPath: remote))
    }
    #expect(recorder.values.contains(.finalizing))
    try assertRemoteTokenizerFilesRecorded(
      outputDir: remoteOutput,
      expectsOptionalSpecialTokens: true)
  }

  @Test func cancellationPreservesCommittedRangesForResume() async throws {
    let snapshotDir = tmpDirForRemote("snap-resume")
    let output = tmpPathForRemote("remote-resume")
    defer { cleanUpRemote([snapshotDir, output]) }
    let snapshot = try SyntheticSnapshot.build(
      at: snapshotDir,
      seed: 0x56_4738_2910)

    resetFakeHF()
    FakeHFURLProtocol.files = try remoteFiles(
      snapshotDir: snapshotDir,
      snap: snapshot,
      includeRequiredTokenizer: true,
      includeOptionalTokenizer: false)
    let seen = Mutex<[UInt64: Int]>([:])
    let task = Task {
      try await RemoteStreamingRepacker(
        options: remoteOptions(outputDir: output, session: fakeHFSession())
      ).run { progress in
        guard case .copyingPayload(_, let downloaded, _) = progress,
              downloaded > 0 else { return }
        let count = seen.withLock {
          $0[downloaded, default: 0] += 1
          return $0[downloaded] ?? 0
        }
        if count == 3 {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
    }
    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }

    let checkpoint = try RemoteInstallCheckpoint.load(from: output + ".resume.json")
    #expect(!checkpoint.completedRanges.isEmpty)

    let result = try await RemoteStreamingRepacker(
      options: remoteOptions(
        outputDir: output,
        session: fakeHFSession(),
        resume: true)
    ).run()
    #expect(result.reusedBytes > 0)
    #expect(result.downloadedThisRunBytes < result.remoteBytesToDownload)
    #expect(FileManager.default.fileExists(
      atPath: (output as NSString).appendingPathComponent("manifest.json")))
  }
}
