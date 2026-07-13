import PackagePlugin

@main
struct VersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let generator = try context.tool(named: "VersionGenerator")
        let input = context.package.directoryURL.appendingPathComponent("VERSION")
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("TreepoolVersion.generated.swift")
        return [
            .buildCommand(
                displayName: "Generate Treepool version",
                executable: generator.url,
                arguments: [input.path, output.path],
                inputFiles: [input],
                outputFiles: [output]
            )
        ]
    }
}
