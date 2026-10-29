// semantic-release: version the action from conventional commits, cut a GitHub
// Release, and move the floating major tag so consumers pinning a major keep
// getting the latest v1.x.x. No CHANGELOG file and no version-bump commit - the
// git tag is the source of truth (matches the other repos here).
export default {
  branches: ["main"],
  plugins: [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/github", { successComment: false, failComment: false }],
    [
      "@semantic-release/exec",
      {
        // The vX.Y.Z tag already exists at this point; repoint vMAJOR at it.
        // exec runs this through lodash.template, so the ${...} must be valid JS.
        publishCmd:
          "git tag -f v${nextRelease.version.split('.')[0]} && git push -f origin v${nextRelease.version.split('.')[0]}",
      },
    ],
  ],
};
