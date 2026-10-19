import PackagePlugin

@main
struct SkillPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let generator = try context.tool(named: "SkillGenerator")
        let input = context.package.directoryURL
            .appendingPathComponent("skills/use-treepool-worktrees/SKILL.md")
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("TreepoolSkill.generated.swift")
        return [
            .buildCommand(
                displayName: "Embed Treepool skill document",
                executable: generator.url,
                arguments: [input.path, output.path],
                inputFiles: [input],
                outputFiles: [output]
            )
        ]
    }
}
