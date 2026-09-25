// Validate the generated feed and DMG against the public key shipped in the app.
// generate_appcast can emit warnings without failing when signing keys mismatch.
import CryptoKit
import Foundation

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "SpaceTreeUpdate", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: message]) }
}

let args = CommandLine.arguments
let plist = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
let key = try Curve25519.Signing.PublicKey(rawRepresentation:
    Data(base64Encoded: info["SUPublicEDKey"] as! String)!)
let feedData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let feed = String(decoding: feedData, as: UTF8.self)
let pattern = #"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n"#
let regex = try NSRegularExpression(pattern: pattern)
guard let match = regex.firstMatch(in: feed, range: NSRange(feed.startIndex..., in: feed)),
      let signatureRange = Range(match.range(at: 1), in: feed),
      let lengthRange = Range(match.range(at: 2), in: feed),
      let signature = Data(base64Encoded: String(feed[signatureRange])),
      let length = Int(feed[lengthRange]), length > 0, length <= feedData.count else {
    fatalError("Missing or malformed appcast signature")
}
let blockRange = Range(match.range, in: feed)!
try require(feedData.count == length + feed[blockRange].utf8.count, "Unexpected unsigned appcast content")
try require(key.isValidSignature(signature, for: Data(feedData.prefix(length))), "Invalid appcast signature")
let xml = try XMLDocument(data: Data(feedData.prefix(length)))
let items = try xml.nodes(forXPath: "/rss/channel/item")
try require(items.count == 1, "Expected exactly one update")
let item = items[0] as! XMLElement
let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let version = item.elements(forLocalName: "version", uri: sparkle).first?.stringValue
try require(version == info["CFBundleVersion"] as? String, "Incorrect update build number")
let enclosure = item.elements(forName: "enclosure").first!
let archiveURL = URL(fileURLWithPath: args[3])
let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
let archiveSignature = Data(base64Encoded: enclosure.attribute(forLocalName: "edSignature", uri: sparkle)!.stringValue!)!
try require(key.isValidSignature(archiveSignature, for: data), "Invalid archive signature")
try require(enclosure.attribute(forName: "length")?.stringValue == String(data.count), "Incorrect archive length")
let repository = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? "codyps/spacetree"
let displayVersion = info["SpaceTreeDisplayVersion"] as! String
let tag = displayVersion.contains("-dev.") ? "development" : "v\(info["CFBundleShortVersionString"] as! String)"
let expectedURL = "https://github.com/\(repository)/releases/download/\(tag)/\(archiveURL.lastPathComponent)"
try require(enclosure.attribute(forName: "url")?.stringValue?.removingPercentEncoding == expectedURL,
            "Incorrect archive download URL")
print("Verified signed appcast and update archive against embedded public key")
