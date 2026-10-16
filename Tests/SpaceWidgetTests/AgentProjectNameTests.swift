import XCTest
@testable import SpaceWidget

final class AgentProjectNameTests: XCTestCase {
    func testPeonCompatibleLabelThenRepositoryThenFolderPriority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("local-folder")
        let child = project.appendingPathComponent("src")
        let git = project.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AgentProjectName.resolve(cwd: project.path, environment: [:]), "local-folder")
        try Data("[remote \"origin\"]\n\turl = git@github.com:team/actual-project.git\n".utf8).write(to: git.appendingPathComponent("config"))
        XCTAssertEqual(AgentProjectName.resolve(cwd: child.path, environment: [:]), "actual-project")
        let label = project.appendingPathComponent(".peon-label")
        try Data("결제 서비스\nignored line".utf8).write(to: label)
        XCTAssertEqual(AgentProjectName.resolve(cwd: project.path, environment: [:]), "결제 서비스")
        XCTAssertEqual(AgentProjectName.resolve(cwd: project.path, environment: ["CLAUDE_SESSION_NAME": "Custom Project"]), "Custom Project")
        XCTAssertNil(AgentProjectName.resolve(cwd: nil, environment: [:]))
        XCTAssertNil(AgentProjectName.resolve(cwd: "/", environment: [:]))
        XCTAssertNil(AgentProjectName.resolve(cwd: "relative", environment: [:]))
        XCTAssertEqual(AgentProjectName.clean(" hello\u{202E}\u{0007} "), "hello")
        XCTAssertEqual(AgentProjectName.clean(String(repeating: "가", count: 60))?.count, 50)
    }

    func testGitWorktreeUsesSharedOriginWithoutPersistingRepositoryPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let worktree = root.appendingPathComponent("feature")
        let git = root.appendingPathComponent("main/.git")
        let worktreeGit = git.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("gitdir: ../main/.git/worktrees/feature\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: worktreeGit.appendingPathComponent("commondir"))
        try Data("[remote \"origin\"]\nurl = https://example.org/company/project.git\n".utf8).write(to: git.appendingPathComponent("config"))
        XCTAssertEqual(AgentProjectName.resolve(cwd: worktree.path, environment: [:]), "project")
    }
}
