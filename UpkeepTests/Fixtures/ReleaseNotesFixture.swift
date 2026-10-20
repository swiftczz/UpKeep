import Foundation

enum ReleaseNotesFixture {
    static let release = URL(
        string: "https://github.com/esengine/DeepSeek-Reasonix/releases/tag/studio-v2.20.0")!
    static let api = URL(
        string:
            "https://api.github.com/repos/esengine/DeepSeek-Reasonix/releases/tags/studio-v2.20.0")!

    // The repository header, tag selector and assets are siblings of the release body.
    static let githubPage = """
        <!doctype html><html><body><nav>Navigation Menu</nav><main>
          <div>esengine / DeepSeek-Reasonix Public</div>
          <ul><li>Notifications You must be signed in</li><li>Fork 2.4k</li><li>Star 35.7k</li></ul>
          <h1>Reasonix Studio v2.20.0</h1><div>Pre-release</div>
          <div>Choose a tag to compare</div><div>Filter</div><div>View all tags</div>
          <div class="markdown-body tmp-my-3" data-test-selector="body-content">
            <p>支持手机配对。</p><h2>新增</h2><ul><li>改进会话同步</li></ul>
          </div>
          <div>Assets 24</div><div>Loading</div><div>All reactions</div>
        </main><footer>Terms Privacy</footer></body></html>
        """
}
