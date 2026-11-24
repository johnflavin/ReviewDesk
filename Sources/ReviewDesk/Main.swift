import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let command = args.first, Headless.commands.contains(command) {
            Task {
                let status = await Headless.run(args)
                exit(status)
            }
            dispatchMain()
        }
        ReviewDeskApp.main()
    }
}
