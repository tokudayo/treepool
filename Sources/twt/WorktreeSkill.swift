// The source document lives in skills/use-treepool-worktrees/SKILL.md.
// SkillPlugin embeds it at build time so installed CLIs need no resource bundle.
enum WorktreeSkill {
    static let contents = TreepoolBuildSkill.contents
}
