// Update signing tool (Ed25519, CryptoKit). The private key never leaves this Mac:
// it is kept in the login Keychain (service "Albumine update signing key").
//
//   swift Resources/update-key.swift generate        creates the key pair, prints the public key
//   swift Resources/update-key.swift public          prints the public key (base64)
//   swift Resources/update-key.swift sign <file>     writes <file>.sig (base64 Ed25519 signature)
//   swift Resources/update-key.swift verify <file>   checks <file>.sig against the public key
//
// Back up the key (Keychain Access › "Albumine update signing key"): without it, future
// releases cannot be signed and installed copies will refuse automatic updates.
import CryptoKit
import Foundation

let service = "Albumine update signing key"
let account = "RoBuys"

func run(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try! p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    let (status, value) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard status == 0, let raw = Data(base64Encoded: value),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write("No signing key in the Keychain. Run: swift Resources/update-key.swift generate\n".data(using: .utf8)!)
        exit(1)
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if run(["find-generic-password", "-s", service, "-a", account]).0 == 0 {
        print("A key already exists; not overwriting it.")
        print(privateKey().publicKey.rawRepresentation.base64EncodedString())
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    let (status, _) = run(["add-generic-password", "-s", service, "-a", account,
                           "-w", key.rawRepresentation.base64EncodedString(),
                           "-j", "Ed25519 private key used to sign Albumine updates. Keep a backup."])
    guard status == 0 else { print("Could not store the key in the Keychain."); exit(1) }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first else { print("usage: sign <file>"); exit(1) }
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let signature = try! privateKey().signature(for: data)
    try! signature.base64EncodedString().write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("Signed: \(path).sig")
case "verify":
    guard let path = args.dropFirst().first else { print("usage: verify <file>"); exit(1) }
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let sig = Data(base64Encoded: try! String(contentsOfFile: path + ".sig", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    let ok = privateKey().publicKey.isValidSignature(sig, for: data)
    print(ok ? "Valid signature" : "INVALID signature")
    exit(ok ? 0 : 1)
default:
    print("usage: swift Resources/update-key.swift generate | public | sign <file> | verify <file>")
}
