import Foundation
import FunctionKeySupport

// stdin belongs exclusively to the app. EOF also occurs if the app is killed,
// so restoration does not depend on its normal termination callback.
let args = CommandLine.arguments
guard args.count == 3, ["0", "1"].contains(args[1]), ["0", "1"].contains(args[2]) else { exit(2) }
let original = args[1] == "1"
let applied = args[2] == "1"
do {
    _ = try FunctionKeyHardware.read()
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    _ = FileHandle.standardInput.readDataToEndOfFile()
    // Preserve a subsequent change made outside this app.
    if try FunctionKeyHardware.read() == applied { try FunctionKeyHardware.write(original) }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
