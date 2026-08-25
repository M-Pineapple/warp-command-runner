import Foundation
import MCP
import Logging

/// Extension to add missing MCP protocol methods
extension WarpCommandRunner {
    
    /// Handle resources/list method
    static func setupResourceHandlers(server: Server, logger: Logger) async {
        await server.withMethodHandler(ListResources.self) { _ in
            logger.debug("Listing resources")
            // Return empty resources for now as we don't expose any
            return ListResources.Result(resources: [])
        }
    }
    
    /// Handle prompts/list method
    static func setupPromptHandlers(server: Server, logger: Logger) async {
        await server.withMethodHandler(ListPrompts.self) { _ in
            logger.debug("Listing prompts")
            // Return empty prompts for now as we don't use any
            return ListPrompts.Result(prompts: [])
        }
    }
}
