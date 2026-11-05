import Foundation
import CryptoKit

/// Where printer certificate pins are kept.
///
/// A Bambu Lab printer presents a self-signed certificate that names its
/// serial, not its IP, so it can't be verified the usual way. Instead the
/// first certificate a printer shows is remembered (trust on first use), once
/// the printer has also accepted the access code. A different certificate
/// later is refused until you call ``forget(_:)``.
///
/// Pins aren't secrets. ``UserDefaultsPinStore`` keeps them across launches;
/// ``MemoryPinStore`` keeps them for the life of the process.
public protocol CertificatePinStore: Sendable {
    /// The pinned SHA-256 fingerprint for a serial, if any.
    func pin(for serial: String) -> String?
    func setPin(_ fingerprint: String?, for serial: String)
}

extension CertificatePinStore {
    /// True when there is no pin yet, or the certificate is the pinned one. Never records anything.
    public func matches(serial: String, leafDER: Data) -> Bool {
        guard let known = pin(for: serial) else { return true }
        return known == certificateFingerprint(leafDER)
    }

    /// Records the pin if there isn't one. Call it only once the broker has
    /// accepted the credentials, so a mistyped IP that answers TLS doesn't get
    /// pinned under this serial.
    public func commit(serial: String, leafDER: Data) {
        guard pin(for: serial) == nil else { return }
        setPin(certificateFingerprint(leafDER), for: serial)
    }

    public func has(_ serial: String) -> Bool { pin(for: serial) != nil }

    /// After a printer was replaced or reset: trust the next certificate it shows.
    public func forget(_ serial: String) { setPin(nil, for: serial) }
}

/// Lowercase hex SHA-256 of a certificate's DER bytes.
public func certificateFingerprint(_ der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
}

/// Pins kept in `UserDefaults`, as a dictionary of serial to fingerprint.
public final class UserDefaultsPinStore: CertificatePinStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "bambu-swift.certificatePins") {
        self.defaults = defaults
        self.key = key
    }

    public func pin(for serial: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[serial]
    }

    public func setPin(_ fingerprint: String?, for serial: String) {
        lock.lock()
        defer { lock.unlock() }
        var pins = load()
        pins[serial] = fingerprint
        defaults.set(pins, forKey: key)
    }

    private func load() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

/// Pins kept in memory only.
public final class MemoryPinStore: CertificatePinStore, @unchecked Sendable {
    private var pins: [String: String]
    private let lock = NSLock()

    public init(pins: [String: String] = [:]) {
        self.pins = pins
    }

    public func pin(for serial: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pins[serial]
    }

    public func setPin(_ fingerprint: String?, for serial: String) {
        lock.lock()
        defer { lock.unlock() }
        pins[serial] = fingerprint
    }
}
