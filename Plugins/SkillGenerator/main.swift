import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: SkillGenerator INPUT OUTPUT")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let contents = try String(contentsOf: input, encoding: .utf8)
// Swift's reflected string literal escapes quotes, newlines, and interpolation markers.
let source = "enum TreepoolBuildSkill { static let contents = \(String(reflecting: contents)) }\n"
try source.write(to: output, atomically: true, encoding: .utf8)
