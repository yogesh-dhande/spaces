import Foundation

struct CLIOutput {
    func emit(_ text: @autoclosure () -> String) { print(text()) }

    func emitLines(_ text: @autoclosure () -> [String]) { for line in text() { print(line) } }
}
