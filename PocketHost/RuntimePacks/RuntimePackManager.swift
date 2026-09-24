import Foundation
import CryptoKit

final class RuntimePackManager: @unchecked Sendable {
    enum PackError: Error { case invalidPayload, integrityFailed, signatureUnavailable, signatureFailed }
    private let lock = NSLock()
    private let root: URL
    private var statuses: [String: RuntimePackStatus] = [:]
    private let trustedPublicKeyBase64: String?

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PocketHost/RuntimePacks", isDirectory: true)
        trustedPublicKeyBase64 = Bundle.main.object(forInfoDictionaryKey: "RuntimePackPublicKey") as? String
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scan()
    }

    func list() -> [RuntimePackStatus] {
        lock.lock(); defer { lock.unlock() }
        return statuses.values.sorted { $0.id < $1.id }
    }

    func install(_ request: RuntimePackInstallRequest) throws -> RuntimePackStatus {
        guard request.manifest.kind == "data" || request.manifest.kind == "wasm",
              isSafeComponent(request.manifest.id),
              isSafeComponent(request.manifest.version),
              isSafeComponent(request.manifest.runtime) else { throw PackError.invalidPayload }
        guard let payload = Data(base64Encoded: request.payloadBase64) else { throw PackError.invalidPayload }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest.lowercased() == request.manifest.sha256.lowercased() else { throw PackError.integrityFailed }
        guard let keyText = trustedPublicKeyBase64, !keyText.isEmpty,
              let keyData = Data(base64Encoded: keyText),
              let signature = Data(base64Encoded: request.manifest.signature) else { throw PackError.signatureUnavailable }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard key.isValidSignature(signature, for: payload) else { throw PackError.signatureFailed }
        let dir = root.appendingPathComponent(request.manifest.id, isDirectory: true).appendingPathComponent(request.manifest.version, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try payload.write(to: dir.appendingPathComponent("payload.bin"), options: .atomic)
        let manifestData = try JSONEncoder().encode(request.manifest)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        let status = RuntimePackStatus(id: request.manifest.id, version: request.manifest.version, runtime: request.manifest.runtime, kind: request.manifest.kind, installedAt: .now)
        lock.lock(); statuses[request.manifest.id] = status; lock.unlock()
        return status
    }

    private func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func scan() {
        guard let packDirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for packDir in packDirs {
            guard let versions = try? FileManager.default.contentsOfDirectory(at: packDir, includingPropertiesForKeys: nil), let latest = versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first,
                  let data = try? Data(contentsOf: latest.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(RuntimePackManifest.self, from: data) else { continue }
            statuses[manifest.id] = RuntimePackStatus(id: manifest.id, version: manifest.version, runtime: manifest.runtime, kind: manifest.kind, installedAt: (try? latest.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now)
        }
    }
}
