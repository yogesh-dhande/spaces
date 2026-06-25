import Foundation

struct CLIContext {
    let output = CLIOutput()

    func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    func currentDirectoryPath() -> String { FileManager.default.currentDirectoryPath }
}
