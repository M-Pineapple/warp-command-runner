import Foundation

// MARK: - Database Models

public struct Project {
    public let id: String
    public let name: String
    public let path: String?
    public let gitRemote: String?
    public let createdAt: Date
    public let metadata: [String: Any]?
}

public struct Template {
    public let id: String
    public let name: String
    public let command: String
    public let description: String?
    public let category: String?
    public let variables: [String]?
    public let usageCount: Int
    public let createdAt: Date
    public let updatedAt: Date
}

public struct CommandStatistics {
    public let totalCommands: Int
    public let successCount: Int
    public let failureCount: Int
    public let averageDuration: Double
    public let topCommands: [(command: String, count: Int)]
    public let topDirectories: [(directory: String, count: Int)]
    public let commandsByHour: [(hour: Int, count: Int)]
    public let commandsByDay: [(date: Date, count: Int)]
    
    public var successRate: Double {
        guard totalCommands > 0 else { return 0 }
        return Double(successCount) / Double(totalCommands) * 100
    }
}

public struct Plugin {
    public let id: String
    public let name: String
    public let version: String?
    public let enabled: Bool
    public let config: [String: Any]?
    public let createdAt: Date
}