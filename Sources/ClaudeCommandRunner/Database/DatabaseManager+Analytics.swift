import Foundation
import SQLite3

// MARK: - Analytics Extensions

extension DatabaseManager {
    
    public func getCommandStatistics(days: Int = 30) -> CommandStatistics {
        return queue.sync {
            guard isOpen else {
                return CommandStatistics(
                    totalCommands: 0, successCount: 0, failureCount: 0,
                    averageDuration: 0, topCommands: [], topDirectories: [],
                    commandsByHour: [], commandsByDay: []
                )
            }
            let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
            
            // Total commands
            let totalCommands = getCount(
                sql: "SELECT COUNT(*) FROM commands WHERE started_at > ?",
                parameters: [cutoffDate.timeIntervalSince1970]
            )
            
            // Success and failure counts
            let (successCount, failureCount) = getSuccessFailureCounts(since: cutoffDate)
            
            // Average duration
            let avgDuration = getAverageDuration(since: cutoffDate)
            
            // Top commands
            let topCommands = getTopCommands(since: cutoffDate, limit: 10)
            
            // Top directories
            let topDirectories = getTopDirectories(since: cutoffDate, limit: 10)
            
            // Commands by hour
            let commandsByHour = getCommandsByHour(since: cutoffDate)
            
            // Commands by day
            let commandsByDay = getCommandsByDay(since: cutoffDate)
            
            return CommandStatistics(
                totalCommands: totalCommands,
                successCount: successCount,
                failureCount: failureCount,
                averageDuration: avgDuration,
                topCommands: topCommands,
                topDirectories: topDirectories,
                commandsByHour: commandsByHour,
                commandsByDay: commandsByDay
            )
        }
    }
    
    private func getCount(sql: String, parameters: [Any] = []) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        
        // Bind parameters
        for (index, param) in parameters.enumerated() {
            if let doubleValue = param as? Double {
                sqlite3_bind_double(statement, Int32(index + 1), doubleValue)
            } else if let intValue = param as? Int {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(intValue))
            } else if let stringValue = param as? String {
                sqlite3_bind_text(statement, Int32(index + 1), stringValue, -1, nil)
            }
        }
        
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        
        return Int(sqlite3_column_int(statement, 0))
    }
    
    private func getSuccessFailureCounts(since date: Date) -> (success: Int, failure: Int) {
        let sql = """
            SELECT 
                COUNT(CASE WHEN exit_code = 0 THEN 1 END) as success_count,
                COUNT(CASE WHEN exit_code != 0 THEN 1 END) as failure_count
            FROM commands 
            WHERE started_at > ? AND exit_code IS NOT NULL
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return (0, 0)
        }
        
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (0, 0)
        }
        
        let successCount = Int(sqlite3_column_int(statement, 0))
        let failureCount = Int(sqlite3_column_int(statement, 1))
        
        return (successCount, failureCount)
    }
    
    private func getAverageDuration(since date: Date) -> Double {
        let sql = """
            SELECT AVG(duration_ms) 
            FROM commands 
            WHERE started_at > ? AND duration_ms IS NOT NULL
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        
        return sqlite3_column_double(statement, 0)
    }
    
    private func getTopCommands(since date: Date, limit: Int) -> [(command: String, count: Int)] {
        let sql = """
            SELECT command, COUNT(*) as count
            FROM commands
            WHERE started_at > ?
            GROUP BY command
            ORDER BY count DESC
            LIMIT ?
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(limit))
        
        var results: [(command: String, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let command = String(cString: sqlite3_column_text(statement, 0))
            let count = Int(sqlite3_column_int(statement, 1))
            results.append((command, count))
        }
        
        return results
    }
    
    private func getTopDirectories(since date: Date, limit: Int) -> [(directory: String, count: Int)] {
        let sql = """
            SELECT directory, COUNT(*) as count
            FROM commands
            WHERE started_at > ? AND directory IS NOT NULL
            GROUP BY directory
            ORDER BY count DESC
            LIMIT ?
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(limit))
        
        var results: [(directory: String, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let directory = String(cString: sqlite3_column_text(statement, 0))
            let count = Int(sqlite3_column_int(statement, 1))
            results.append((directory, count))
        }
        
        return results
    }
    
    private func getCommandsByHour(since date: Date) -> [(hour: Int, count: Int)] {
        let sql = """
            SELECT 
                CAST(strftime('%H', datetime(started_at, 'unixepoch')) AS INTEGER) as hour,
                COUNT(*) as count
            FROM commands
            WHERE started_at > ?
            GROUP BY hour
            ORDER BY hour
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        
        var results: [(hour: Int, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let hour = Int(sqlite3_column_int(statement, 0))
            let count = Int(sqlite3_column_int(statement, 1))
            results.append((hour, count))
        }
        
        return results
    }
    
    private func getCommandsByDay(since date: Date) -> [(date: Date, count: Int)] {
        let sql = """
            SELECT 
                date(datetime(started_at, 'unixepoch')) as day,
                COUNT(*) as count
            FROM commands
            WHERE started_at > ?
            GROUP BY day
            ORDER BY day
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        
        var results: [(date: Date, count: Int)] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        while sqlite3_step(statement) == SQLITE_ROW {
            if let dayString = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
               let day = dateFormatter.date(from: dayString) {
                let count = Int(sqlite3_column_int(statement, 1))
                results.append((day, count))
            }
        }
        
        return results
    }
    
    // MARK: - Counts

    /// Cheap row count for health checks (avoids materialising full records).
    public func commandCount() -> Int {
        return queue.sync {
            guard isOpen else { return 0 }
            return getCount(sql: "SELECT COUNT(*) FROM commands")
        }
    }

    // MARK: - Cleanup

    public func cleanupOldCommands(olderThan days: Int) -> Int {
        return queue.sync {
            guard isOpen else { return 0 }
            let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
            let sql = "DELETE FROM commands WHERE started_at < ?"

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return 0
            }

            sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                return 0
            }

            return Int(sqlite3_changes(db))
        }
    }

    /// Prune analytics events past the retention window. Analytics were
    /// previously written on every command with no cleanup path at all,
    /// so the table grew without bound.
    public func cleanupOldAnalytics(olderThan days: Int) -> Int {
        return queue.sync {
            guard isOpen else { return 0 }
            let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
            // The analytics timestamp column is CURRENT_TIMESTAMP text, so
            // compare against an ISO-ish datetime rather than a unix epoch.
            let sql = "DELETE FROM analytics WHERE timestamp < datetime(?, 'unixepoch')"

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return 0
            }

            sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                return 0
            }

            return Int(sqlite3_changes(db))
        }
    }

    public func vacuum() {
        queue.async {
            guard self.isOpen else { return }
            sqlite3_exec(self.db, "VACUUM", nil, nil, nil)
        }
    }

    /// Startup maintenance: bound history growth and reclaim space.
    /// Called once from run(); cleanupOldCommands/vacuum previously existed
    /// but had no callers anywhere.
    public func performStartupMaintenance(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        let removedCommands = cleanupOldCommands(olderThan: retentionDays)
        let removedEvents = cleanupOldAnalytics(olderThan: retentionDays)
        if removedCommands > 0 || removedEvents > 0 {
            vacuum()
        }
    }
}