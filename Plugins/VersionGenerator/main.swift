import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: VersionGenerator INPUT OUTPUT")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let version = try String(contentsOf: input, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
    fatalError("VERSION must contain a semantic version such as 0.1.0")
}
try "enum TreepoolBuildVersion { static let value = \"\(version)\" }\n"
    .write(to: output, atomically: true, encoding: .utf8)
