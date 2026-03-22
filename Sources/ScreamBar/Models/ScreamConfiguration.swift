import Foundation

struct ScreamConfiguration: Codable, Equatable {
    var useUnicast: Bool = false
    var port: Int = 4010

    func buildArguments() -> [String] {
        var arguments = ["-o", "jack"]

        if useUnicast {
            arguments.append("-u")
        }

        if port != 4010 {
            arguments += ["-p", String(port)]
        }

        return arguments
    }
}
