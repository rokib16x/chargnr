import ChargnrCore
import Foundation

let usage = """
    usage: chargnr <command>

    commands:
      version            print the version
      keys --fake NAME   list charging keys on a fake Mac (\(FakeSMC.Profile.allCases.map(\.rawValue).joined(separator: ", ")))
      help               show this help
    """

let chargingKeys: [SMCKey] = ["CH0B", "CH0C", "CHTE", "CH0I", "CH0J", "CHIE", "bfF0", "bfD0", "bfE0", "ACLC", "BUIC", "AC-W"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("chargnr: \(message)\n".utf8))
    exit(64)
}

var args = CommandLine.arguments.dropFirst()

switch args.popFirst() {
case "version", "--version", "-v":
    print("chargnr \(Chargnr.version)")
case "keys":
    guard args.popFirst() == "--fake", let name = args.popFirst(), let profile = FakeSMC.Profile(rawValue: name) else {
        fail("keys needs --fake NAME (real hardware arrives in phase 1)")
    }
    let smc = FakeSMC(profile: profile)
    for key in chargingKeys {
        guard let info = try smc.keyInfo(key) else { continue }
        let hex = try smc.read(key).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("\(key)  \(info.type)  \(info.size)B  \(hex)")
    }
case "help", "--help", "-h", nil:
    print(usage)
case let other?:
    fail("unknown command '\(other)'\n\(usage)")
}
