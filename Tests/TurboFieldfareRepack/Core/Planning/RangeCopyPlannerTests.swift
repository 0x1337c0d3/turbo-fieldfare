import Darwin
import Foundation
import Testing
@testable import TurboFieldfareRepackCore

@Suite
struct RangeCopyPlannerTests {
    @Test func sharedExpertOverridesReplaceOnlySharedResidentWeights() throws {
        let primaryDirectory = temporaryRoot("primary-4bit")
        let auxiliaryDirectory = temporaryRoot("shared-8bit")
        let output = temporaryRoot("hybrid-output")
        defer {
            try? FileManager.default.removeItem(atPath: primaryDirectory)
            try? FileManager.default.removeItem(atPath: auxiliaryDirectory)
            try? FileManager.default.removeItem(atPath: output)
        }
        let primary = try SyntheticSnapshot.build(
            at: primaryDirectory, seed: 0x1111, sharedExpertBits: 4)
        let auxiliary = try SyntheticSnapshot.build(
            at: auxiliaryDirectory, seed: 0x2222, sharedExpertBits: 8)
        let primaryMetadata = try IndexLoader.load(snapshotDir: primaryDirectory)
        let auxiliaryMetadata = try IndexLoader.load(snapshotDir: auxiliaryDirectory)
        let arch = try ArchInfo.load(configPath:
            (primaryDirectory as NSString).appendingPathComponent("config.json"))
        let overrides = try RepackPlanner.sharedExpertOverrides(
            meta: auxiliaryMetadata,
            arch: arch,
            shardHeaders: [try parseHeader(path: auxiliary.shardPath)],
            sourceNamespace: "shared8")
        let plan = try RepackPlanner.plan(
            meta: primaryMetadata,
            arch: arch,
            shardHeaders: [try parseHeader(path: primary.shardPath)],
            outputDir: output,
            sharedExpertOverrides: overrides)

        let shared = plan.resident.entries.filter { $0.name.contains(".mlp.") }
        let otherQuantized = plan.resident.entries.filter {
            $0.quantSpec != nil && !$0.name.contains(".mlp.")
        }
        #expect(shared.count == arch.numLayers * 3)
        #expect(shared.allSatisfy { $0.quantSpec?.bits == 8 })
        #expect(shared.allSatisfy { $0.sourceWeight.shardPath.hasPrefix("shared8/") })
        #expect(otherQuantized.allSatisfy { !$0.sourceWeight.shardPath.hasPrefix("shared8/") })
    }

    @Test func sharedExpertOverridesRequireGenuineEightBitWeights() throws {
        let directory = temporaryRoot("invalid-shared-override")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let snapshot = try SyntheticSnapshot.build(
            at: directory, seed: 0x3333, sharedExpertBits: 4)
        let metadata = try IndexLoader.load(snapshotDir: directory)
        let arch = try ArchInfo.load(configPath:
            (directory as NSString).appendingPathComponent("config.json"))

        #expect(throws: RepackError.self) {
            _ = try RepackPlanner.sharedExpertOverrides(
                meta: metadata,
                arch: arch,
                shardHeaders: [try parseHeader(path: snapshot.shardPath)],
                sourceNamespace: "shared8")
        }
    }

    @Test func canonicalFingerprintDoesNotDependOnAbsoluteOutputRoot() throws {
        let snapshotDirectory = temporaryRoot("snapshot")
        let firstOutput = temporaryRoot("first")
        let secondOutput = temporaryRoot("second")
        defer {
            try? FileManager.default.removeItem(atPath: snapshotDirectory)
            try? FileManager.default.removeItem(atPath: firstOutput)
            try? FileManager.default.removeItem(atPath: secondOutput)
        }
        let snapshot = try SyntheticSnapshot.build(
            at: snapshotDirectory,
            seed: 0x1020_3040)
        let metadata = try IndexLoader.load(snapshotDir: snapshotDirectory)
        let arch = try ArchInfo.load(
            configPath: (snapshotDirectory as NSString).appendingPathComponent("config.json"))
        let header = try parseHeader(path: snapshot.shardPath)
        let firstPlan = try RepackPlanner.plan(
            meta: metadata,
            arch: arch,
            shardHeaders: [header],
            outputDir: firstOutput)
        let secondPlan = try RepackPlanner.plan(
            meta: metadata,
            arch: arch,
            shardHeaders: [header],
            outputDir: secondOutput)

        let first = try RangeCopyPlanner.plan(
            repackPlan: firstPlan,
            rangeChunkBytes: 4096)
        let second = try RangeCopyPlanner.plan(
            repackPlan: secondPlan,
            rangeChunkBytes: 4096)

        #expect(first.canonicalFingerprint == second.canonicalFingerprint)
        #expect(first.coalescedCopies.map(\.id) == second.coalescedCopies.map(\.id))
    }

    @Test func overlappingDestinationIntervalsAreRejected() throws {
        let root = temporaryRoot("overlap")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let output = (root as NSString).appendingPathComponent("file.bin")
        let copies = [
            RangeCopy(
                shardID: "source.bin",
                sourceOffset: 0,
                size: 10,
                destinationPath: output,
                destinationOffset: 0),
            RangeCopy(
                shardID: "source.bin",
                sourceOffset: 20,
                size: 10,
                destinationPath: output,
                destinationOffset: 9),
        ]

        #expect(throws: RepackError.self) {
            try RangeCopyPlanner.validateDestinationIntervals(
                copies,
                outputRoot: root)
        }
    }

    @Test func normalizedRelativePathRejectsEscape() throws {
        let root = temporaryRoot("escape")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = (root as NSString).deletingLastPathComponent
            + "/outside.bin"

        #expect(throws: RepackError.self) {
            _ = try RangeCopyPlanner.normalizedRelativePath(
                outside,
                root: root)
        }
    }

    private func temporaryRoot(_ tag: String) -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("turbofieldfare-range-plan-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true)
        return path
    }

    private func parseHeader(path: String) throws -> Safetensors.Header {
        let fd = try Posix.openRead(path)
        defer { close(fd) }
        var headerSize: UInt64 = 0
        try withUnsafeMutableBytes(of: &headerSize) {
            try Posix.preadAll(
                fd: fd,
                path: path,
                buf: $0.baseAddress!,
                count: 8,
                offset: 0)
        }
        headerSize = UInt64(littleEndian: headerSize)
        var headerData = Data(count: Int(headerSize))
        try headerData.withUnsafeMutableBytes {
            try Posix.preadAll(
                fd: fd,
                path: path,
                buf: $0.baseAddress!,
                count: $0.count,
                offset: 8)
        }
        return try Safetensors.parseHeaderBytes(
            path: path,
            fileSize: try Posix.fileSize(fd: fd, path: path),
            headerBytes: headerData)
    }
    @Test func visionPlanIsBoundToTextManifestButNotAbsoluteOutputRoot() throws {
        let firstRoot = temporaryRoot("vision-first")
        let secondRoot = temporaryRoot("vision-second")
        defer {
            try? FileManager.default.removeItem(atPath: firstRoot)
            try? FileManager.default.removeItem(atPath: secondRoot)
        }
        let source = SourceTensor(
            name: "vision.weight",
            shardPath: "model-00001.safetensors",
            dtype: .bf16,
            shape: [2],
            absoluteOffset: 128,
            sizeBytes: 4)
        let plan = VisionPackPlan(
            entries: [.init(
                source: source,
                executionPosition: 0,
                fileOffset: 0,
                quantSpec: nil,
                groupSize: 64)],
            weightsFileSize: 16_384,
            sourcePayloadBytes: 4)
        let binding = String(repeating: "a", count: 64)
        let first = try RangeCopyPlanner.plan(
            visionPackPlan: plan,
            outputDirectory: firstRoot,
            rangeChunkBytes: 4096,
            textManifestSha256: binding)
        let second = try RangeCopyPlanner.plan(
            visionPackPlan: plan,
            outputDirectory: secondRoot,
            rangeChunkBytes: 4096,
            textManifestSha256: binding)
        let changedBinding = try RangeCopyPlanner.plan(
            visionPackPlan: plan,
            outputDirectory: secondRoot,
            rangeChunkBytes: 4096,
            textManifestSha256: String(repeating: "b", count: 64))

        #expect(first.canonicalFingerprint == second.canonicalFingerprint)
        #expect(first.canonicalFingerprint != changedBinding.canonicalFingerprint)
        #expect(first.remoteBytesToDownload == 4)
        #expect(first.expectedOutputs == [RemoteExpectedOutput(
            relativePath: "vision_weights.bin",
            size: 16_384)])
    }

}
