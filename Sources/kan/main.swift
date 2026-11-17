import Foundation
import KanAgent
import KanCore

// `kan`: the command-line tool and MCP server for AI agents. All logic lives in KanAgent.
KanLog.configure(fileName: "kan-cli.log")
let code = await KanCLI.run(Array(CommandLine.arguments.dropFirst()), context: .standard(transcribe: TranscribeHook.run))
exit(code)
