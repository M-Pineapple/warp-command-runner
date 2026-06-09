import Foundation
import SQLite3
import Logging

// SQLite constants
fileprivate let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite database manager for Claude Command Runner
public class DatabaseManager {
    internal var db: OpaquePointer?
    private let dbPath: String
    // Serial queue: SQLite connections are not safe for concurrent use from
    // multiple threads unless the library is in serialized threading mode,
    // which the system libsqlite3 does not guarantee. A serial queue (plus
    // SQLITE_OPEN_FULLMUTEX, belt and braces) removes the data race; SQLite
    // serialises internally anyway, so the old concurrent-reader design
    // bought nothing.
    internal let queue = DispatchQueue(label: "com.claude-command-runner.database")
    private let logger = Logger(label: "com.claude.command-runner.database")

    /// Current schema version; bump and add a migration step in migrateIfNeeded().
    private static let schemaVersion: Int32 = 1

    public static let shared = DatabaseManager()
    
    private init() {
        // Default database location
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let dbDirectory = homeDir.appendingPathComponent(".claude-command-runner")
        try? FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        
        self.dbPath = dbDirectory.appendingPathComponent("claude_commands.db").path
        setupDatabase()
    }
    
    public init(path: String) {
        self.dbPath = path
        setupDatabase()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    // MARK: - Setup
    
    /// Open the database with serialized threading mode requested explicitly.
    private func openDatabase() -> Int32 {
        return sqlite3_open_v2(
            dbPath,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
    }

    private func setupDatabase() {
        // NOTE: never print() in this class — the MCP server speaks JSON-RPC
        // over stdout, so stray stdout output corrupts the protocol stream.
        // The Logging backend writes to stderr.
        logger.debug("Setting up database at: \(dbPath)")

        // Check if database exists and verify integrity
        if FileManager.default.fileExists(atPath: dbPath) {
            logger.debug("Existing database found, checking integrity...")

            // Open database
            let result = openDatabase()
            if result != SQLITE_OK {
                logger.error("Error opening database (code \(result)): \(String(cString: sqlite3_errmsg(db)))")
                handleCorruptedDatabase()
                return
            }

            // Check integrity
            var integrityOK = true
            let checkSQL = "PRAGMA integrity_check;"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, checkSQL, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let result = sqlite3_column_text(statement, 0) {
                        let resultStr = String(cString: result)
                        if resultStr != "ok" {
                            logger.error("Integrity check failed: \(resultStr)")
                            integrityOK = false
                            break
                        }
                    }
                }
            }
            sqlite3_finalize(statement)

            if !integrityOK {
                logger.warning("Database corrupted, recreating...")
                sqlite3_close(db)
                db = nil
                handleCorruptedDatabase()
                return
            }

            logger.debug("Database integrity check passed")
        } else {
            logger.debug("No existing database, creating new one...")

            // Create new database
            let result = openDatabase()
            if result != SQLITE_OK {
                logger.error("Error creating database (code \(result)): \(String(cString: sqlite3_errmsg(db)))")
                db = nil
                return
            }
        }

        // Enable foreign keys
        execute("PRAGMA foreign_keys = ON")

        // Create tables
        createTables()
        migrateIfNeeded()

        logger.debug("Database setup complete")
    }

    private func handleCorruptedDatabase() {
        // Make sure a half-open handle from the failed sqlite3_open_v2 is
        // released before we move the file out of the way.
        if db != nil {
            sqlite3_close(db)
            db = nil
        }

        // Backup corrupted database
        let backupPath = dbPath + ".corrupted.\(Date().timeIntervalSince1970)"
        try? FileManager.default.moveItem(atPath: dbPath, toPath: backupPath)
        logger.warning("Corrupted database backed up to: \(backupPath)")

        // Create new database
        let result = openDatabase()
        if result != SQLITE_OK {
            logger.critical("Failed to create new database: \(String(cString: sqlite3_errmsg(db)))")
            // Leave db nil; all operations check isOpen and degrade gracefully.
            db = nil
            return
        }

        logger.info("New database created successfully")

        // Enable foreign keys
        execute("PRAGMA foreign_keys = ON")

        // Create tables
        createTables()
        migrateIfNeeded()
    }

    /// True when a usable SQLite handle is available. Every operation must
    /// check this: calling sqlite3_* with a NULL handle is undefined behaviour.
    internal var isOpen: Bool { db != nil }

    /// Read PRAGMA user_version and apply migrations as needed.
    private func migrateIfNeeded() {
        guard isOpen else { return }
        var statement: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)

        if version < Self.schemaVersion {
            // Future migrations go here, gated on `version`. Version 1 is the
            // baseline created by createTables().
            execute("PRAGMA user_version = \(Self.schemaVersion)")
            logger.debug("Schema version set to \(Self.schemaVersion) (was \(version))")
        }
    }
    
    private func createTables() {
        // Commands table
        let createCommandsTable = """
            CREATE TABLE IF NOT EXISTS commands (
                id TEXT PRIMARY KEY,
                command TEXT NOT NULL,
                directory TEXT,
                exit_code INTEGER,
                stdout TEXT,
                stderr TEXT,
                started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                completed_at TIMESTAMP,
                duration_ms INTEGER,
                terminal_type TEXT,
                project_id TEXT,
                tags TEXT,
                metadata TEXT,
                FOREIGN KEY (project_id) REFERENCES projects(id)
            )
        """
        
        // Projects table
        let createProjectsTable = """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                path TEXT,
                git_remote TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata TEXT
            )
        """
        
        // Templates table
        let createTemplatesTable = """
            CREATE TABLE IF NOT EXISTS templates (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                command TEXT NOT NULL,
                description TEXT,
                category TEXT,
                variables TEXT,
                usage_count INTEGER DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        
        // Plugins table
        let createPluginsTable = """
            CREATE TABLE IF NOT EXISTS plugins (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                version TEXT,
                enabled INTEGER DEFAULT 1,
                config TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        
        // Analytics table
        let createAnalyticsTable = """
            CREATE TABLE IF NOT EXISTS analytics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_type TEXT NOT NULL,
                event_data TEXT,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        
        // Create indexes
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_commands_started_at ON commands(started_at)",
            "CREATE INDEX IF NOT EXISTS idx_commands_project_id ON commands(project_id)",
            "CREATE INDEX IF NOT EXISTS idx_commands_exit_code ON commands(exit_code)",
            "CREATE INDEX IF NOT EXISTS idx_commands_directory ON commands(directory)",
            "CREATE INDEX IF NOT EXISTS idx_templates_category ON templates(category)",
            "CREATE INDEX IF NOT EXISTS idx_analytics_event_type ON analytics(event_type)",
            "CREATE INDEX IF NOT EXISTS idx_analytics_timestamp ON analytics(timestamp)"
        ]
        
        // Execute all CREATE statements
        for statement in [createCommandsTable, createProjectsTable, createTemplatesTable,
                         createPluginsTable, createAnalyticsTable] + indexes {
            if !execute(statement) {
                logger.error("Failed to create table/index")
            }
        }
    }

    // MARK: - Core Operations

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        return queue.sync {
            guard isOpen else { return false }
            let result = sqlite3_exec(db, sql, nil, nil, nil)
            if result != SQLITE_OK {
                logger.error("SQL Error: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            return true
        }
    }
    
    // MARK: - Command Operations
    
    public func saveCommand(_ command: CommandRecord) -> Bool {
        return queue.sync {
            guard isOpen else { return false }
            let sql = """
                INSERT INTO commands (id, command, directory, exit_code, stdout, stderr,
                                    started_at, completed_at, duration_ms, terminal_type,
                                    project_id, tags, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                logger.error("Failed to prepare INSERT statement: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            
            // Bind parameters with proper memory management
            sqlite3_bind_text(statement, 1, command.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, command.command, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, command.directory, -1, SQLITE_TRANSIENT)
            
            if let exitCode = command.exitCode {
                sqlite3_bind_int(statement, 4, Int32(exitCode))
            } else {
                sqlite3_bind_null(statement, 4)
            }
            
            sqlite3_bind_text(statement, 5, command.stdout, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 6, command.stderr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 7, command.startedAt.timeIntervalSince1970)
            
            if let completedAt = command.completedAt {
                sqlite3_bind_double(statement, 8, completedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 8)
            }
            
            if let duration = command.durationMs {
                sqlite3_bind_int(statement, 9, Int32(duration))
            } else {
                sqlite3_bind_null(statement, 9)
            }
            
            sqlite3_bind_text(statement, 10, command.terminalType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 11, command.projectId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 12, command.tags?.joined(separator: ","), -1, SQLITE_TRANSIENT)
            
            if let metadata = command.metadata,
               let jsonData = try? JSONSerialization.data(withJSONObject: metadata),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                sqlite3_bind_text(statement, 13, jsonString, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 13)
            }
            
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                logger.debug("Command saved: \(command.id)")
                return true
            } else {
                logger.error("Failed to save command (step result \(stepResult)): \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
        }
    }

    public func updateCommand(_ commandId: String, stdout: String?, stderr: String?, exitCode: Int?, completedAt: Date) -> Bool {
        // Resolve the start time OUTSIDE the sync block: getCommandStartTime runs
        // its own queue.sync, and nesting that inside a block on the same queue
        // deadlocks. (Latent since this method had no callers until v6.0.5.)
        let startTime = getCommandStartTime(commandId)
        return queue.sync {
            guard isOpen else { return false }
            let duration = startTime.map { Int(completedAt.timeIntervalSince($0) * 1000) }

            let sql = """
                UPDATE commands 
                SET stdout = ?, stderr = ?, exit_code = ?, completed_at = ?, duration_ms = ?
                WHERE id = ?
            """
            
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            
            sqlite3_bind_text(statement, 1, stdout, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, stderr, -1, SQLITE_TRANSIENT)
            
            if let exitCode = exitCode {
                sqlite3_bind_int(statement, 3, Int32(exitCode))
            } else {
                sqlite3_bind_null(statement, 3)
            }
            
            sqlite3_bind_double(statement, 4, completedAt.timeIntervalSince1970)
            
            if let duration = duration {
                sqlite3_bind_int(statement, 5, Int32(duration))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            
            sqlite3_bind_text(statement, 6, commandId, -1, SQLITE_TRANSIENT)
            
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }
    
    private func getCommandStartTime(_ commandId: String) -> Date? {
        return queue.sync {
            guard isOpen else { return nil }
            let sql = "SELECT started_at FROM commands WHERE id = ?"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return nil
            }
            
            sqlite3_bind_text(statement, 1, commandId, -1, SQLITE_TRANSIENT)
            
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            
            let timestamp = sqlite3_column_double(statement, 0)
            return Date(timeIntervalSince1970: timestamp)
        }
    }
    
    public func getRecentCommands(limit: Int = 10) -> [CommandRecord] {
        return queue.sync {
            guard isOpen else { return [] }
            let sql = """
                SELECT id, command, directory, exit_code, stdout, stderr, 
                       started_at, completed_at, duration_ms, terminal_type, 
                       project_id, tags, metadata
                FROM commands
                ORDER BY started_at DESC
                LIMIT ?
            """
            
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            
            sqlite3_bind_int(statement, 1, Int32(limit))
            
            var commands: [CommandRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let command = parseCommandRow(from: statement) {
                    commands.append(command)
                }
            }
            
            return commands
        }
    }
    
    private func parseCommandRow(from statement: OpaquePointer?) -> CommandRecord? {
        guard let statement = statement else { return nil }
        
        let id = String(cString: sqlite3_column_text(statement, 0))
        let command = String(cString: sqlite3_column_text(statement, 1))
        let directory = sqlite3_column_text(statement, 2).map { String(cString: $0) }
        let exitCode = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3))
        let stdout = sqlite3_column_text(statement, 4).map { String(cString: $0) }
        let stderr = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        let completedAt = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let durationMs = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 8))
        let terminalType = sqlite3_column_text(statement, 9).map { String(cString: $0) }
        let projectId = sqlite3_column_text(statement, 10).map { String(cString: $0) }
        let tagsString = sqlite3_column_text(statement, 11).map { String(cString: $0) }
        let tags = tagsString?.split(separator: ",").map(String.init)
        
        var metadata: [String: Any]?
        if let metadataString = sqlite3_column_text(statement, 12).map({ String(cString: $0) }),
           let data = metadataString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metadata = json
        }
        
        return CommandRecord(
            id: id,
            command: command,
            directory: directory,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: durationMs,
            terminalType: terminalType,
            projectId: projectId,
            tags: tags,
            metadata: metadata
        )
    }
    
    // MARK: - Search
    
    public func searchCommands(query: String, limit: Int = 50) -> [CommandRecord] {
        return queue.sync {
            guard isOpen else { return [] }
            let sql = """
                SELECT id, command, directory, exit_code, stdout, stderr, 
                       started_at, completed_at, duration_ms, terminal_type, 
                       project_id, tags, metadata
                FROM commands
                WHERE command LIKE ? OR directory LIKE ? OR tags LIKE ?
                ORDER BY started_at DESC
                LIMIT ?
            """
            
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            
            let searchPattern = "%\(query)%"
            sqlite3_bind_text(statement, 1, searchPattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, searchPattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, searchPattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 4, Int32(limit))
            
            var commands: [CommandRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let command = parseCommandRow(from: statement) {
                    commands.append(command)
                }
            }
            
            return commands
        }
    }
}

// MARK: - Extensions

extension DatabaseManager {
    
    // MARK: - Project Management
    
    public func createProject(name: String, path: String?, gitRemote: String? = nil) -> String? {
        return queue.sync {
            guard isOpen else { return nil }
            let id = UUID().uuidString
            let sql = """
                INSERT INTO projects (id, name, path, git_remote)
                VALUES (?, ?, ?, ?)
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                logger.error("Failed to prepare project insert: \(String(cString: sqlite3_errmsg(db)))")
                return nil
            }

            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, gitRemote, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                logger.error("Failed to insert project: \(String(cString: sqlite3_errmsg(db)))")
                return nil
            }
            
            return id
        }
    }
    
    public func getProject(byPath path: String) -> Project? {
        return queue.sync {
            guard isOpen else { return nil }
            let sql = "SELECT id, name, path, git_remote, created_at, metadata FROM projects WHERE path = ?"
            
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return nil
            }
            
            sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
            
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            
            return parseProjectRow(from: statement)
        }
    }
    
    public func detectProjectFromDirectory(_ directory: String) -> String? {
        // First check if we have an exact match
        if let project = getProject(byPath: directory) {
            return project.id
        }
        
        // Check if directory is within a known project
        return queue.sync {
            guard isOpen else { return nil }
            let sql = """
                SELECT id, name, path FROM projects
                WHERE ? LIKE path || '%'
                ORDER BY LENGTH(path) DESC
                LIMIT 1
            """
            
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return nil
            }
            
            sqlite3_bind_text(statement, 1, directory, -1, SQLITE_TRANSIENT)
            
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            
            return String(cString: sqlite3_column_text(statement, 0))
        }
    }
    
    private func parseProjectRow(from statement: OpaquePointer?) -> Project? {
        guard let statement = statement else { return nil }
        
        let id = String(cString: sqlite3_column_text(statement, 0))
        let name = String(cString: sqlite3_column_text(statement, 1))
        let path = sqlite3_column_text(statement, 2).map { String(cString: $0) }
        let gitRemote = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        
        var metadata: [String: Any]?
        if let metadataString = sqlite3_column_text(statement, 5).map({ String(cString: $0) }),
           let data = metadataString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metadata = json
        }
        
        return Project(
            id: id,
            name: name,
            path: path,
            gitRemote: gitRemote,
            createdAt: createdAt,
            metadata: metadata
        )
    }
    
    // MARK: - Template Management
    
    public func getTemplates(category: String? = nil) -> [Template] {
        return queue.sync {
            guard isOpen else { return [] }
            var sql = """
                SELECT id, name, command, description, category, variables, usage_count, created_at, updated_at
                FROM templates
            """
            
            if category != nil {
                sql += " WHERE category = ?"
            }
            
            sql += " ORDER BY usage_count DESC, name ASC"
            
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }
            
            if let category = category {
                sqlite3_bind_text(statement, 1, category, -1, SQLITE_TRANSIENT)
            }
            
            var templates: [Template] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let template = parseTemplateRow(from: statement) {
                    templates.append(template)
                }
            }
            
            return templates
        }
    }
    
    private func parseTemplateRow(from statement: OpaquePointer?) -> Template? {
        guard let statement = statement else { return nil }
        
        let id = String(cString: sqlite3_column_text(statement, 0))
        let name = String(cString: sqlite3_column_text(statement, 1))
        let command = String(cString: sqlite3_column_text(statement, 2))
        let description = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let category = sqlite3_column_text(statement, 4).map { String(cString: $0) }
        
        var variables: [String]?
        if let variablesString = sqlite3_column_text(statement, 5).map({ String(cString: $0) }),
           let data = variablesString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String] {
            variables = json
        }
        
        let usageCount = Int(sqlite3_column_int(statement, 6))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        
        return Template(
            id: id,
            name: name,
            command: command,
            description: description,
            category: category,
            variables: variables,
            usageCount: usageCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
    
    // MARK: - Analytics
    
    public func recordAnalyticsEvent(_ eventType: String, data: [String: Any]? = nil) {
        queue.async {
            guard self.isOpen else { return }
            let sql = "INSERT INTO analytics (event_type, event_data) VALUES (?, ?)"

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.logger.error("Failed to prepare analytics insert: \(String(cString: sqlite3_errmsg(self.db)))")
                return
            }
            
            sqlite3_bind_text(statement, 1, eventType, -1, SQLITE_TRANSIENT)
            
            if let data = data,
               let jsonData = try? JSONSerialization.data(withJSONObject: data),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                sqlite3_bind_text(statement, 2, jsonString, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            
            sqlite3_step(statement)
        }
    }
}

// MARK: - Models

public struct CommandRecord {
    public let id: String
    public let command: String
    public let directory: String?
    public let exitCode: Int?
    public let stdout: String?
    public let stderr: String?
    public let startedAt: Date
    public let completedAt: Date?
    public let durationMs: Int?
    public let terminalType: String?
    public let projectId: String?
    public let tags: [String]?
    public let metadata: [String: Any]?
    
    public init(
        id: String = UUID().uuidString,
        command: String,
        directory: String? = nil,
        exitCode: Int? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        durationMs: Int? = nil,
        terminalType: String? = nil,
        projectId: String? = nil,
        tags: [String]? = nil,
        metadata: [String: Any]? = nil
    ) {
        self.id = id
        self.command = command
        self.directory = directory
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.terminalType = terminalType
        self.projectId = projectId
        self.tags = tags
        self.metadata = metadata
    }
}