import Foundation

/// The index database's layout.
///
/// A searchable row is a turn: one user prompt plus the assistant replies after it, so a query's words
/// must all occur within one turn. `turns` maps each FTS rowid to its session and to the transcript the
/// turn came from (a hash of the file path; a session folds in subagent transcripts, and a continuation
/// must extend a turn of the same transcript). A search joins it to find the session of a match (measured
/// on 125,000 rows: reading an UNINDEXED `session` column out of the FTS content row made the scan about
/// five times slower than this primary-key join), and a session's rows are deleted through it. The rowid
/// of a turn encodes the time of its newest message (see `TurnRowID`), which the newest-first search
/// depends on (see `AgentSessionIndex.search`).
enum SessionIndexSchema {
    /// Bumped whenever the tables, the tokenizer, or what the readers extract changes, so every existing
    /// index is rebuilt from the stores.
    static let formatVersion: Int64 = 2

    static let createStatements: [String] = [
        """
        CREATE TABLE sessions (
            id INTEGER PRIMARY KEY,
            agent TEXT NOT NULL,
            source_id TEXT NOT NULL,
            session_key TEXT NOT NULL,
            title TEXT,
            first_prompt TEXT,
            cwd TEXT,
            last_active REAL NOT NULL,
            size_bytes INTEGER NOT NULL,
            is_one_shot INTEGER NOT NULL DEFAULT 0,
            turn_count INTEGER NOT NULL DEFAULT 0,
            UNIQUE (agent, source_id)
        )
        """, "CREATE INDEX sessions_by_last_active ON sessions (last_active DESC, id DESC)",
        """
        CREATE TABLE source_files (
            session_id INTEGER NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            inode INTEGER NOT NULL,
            read_offset INTEGER,
            PRIMARY KEY (session_id, path)
        ) WITHOUT ROWID
        """, "CREATE TABLE turns (rowid INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, transcript INTEGER NOT NULL)",
        "CREATE INDEX turns_by_session ON turns (session_id, transcript)",
        "CREATE TABLE index_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID",
        """
        CREATE VIRTUAL TABLE turn_text USING fts5(
            text, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
        )
        """,
    ]
}
