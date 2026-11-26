import CryptoKit
import Foundation

// Verify using only the public key already trusted by installed applications.
let args = CommandLine.arguments
guard args.count == 4, let publicBytes = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]) else { exit(1) }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard publicKey.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Archive signature does not match the app's public key\n".utf8))
    exit(1)
}
