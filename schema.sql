-- Agent Cortex — PostgreSQL Schema
-- PostgreSQL + pgvector
-- Embedding: NVIDIA llama-nemotron-embed (2048 dims) via OpenRouter (FREE)
-- Index: ivfflat (pgvector hnsw has 2000-dim limit)
--
-- Usage (Podman):
--   podman cp schema.sql mem-postgres:/tmp/schema.sql
--   podman exec mem-postgres psql -U postgres -d <dbname> -f /tmp/schema.sql
--
-- Usage (Docker):
--   docker cp schema.sql mem-postgres:/tmp/schema.sql
--   docker exec mem-postgres psql -U postgres -d <dbname> -f /tmp/schema.sql
--
-- Schema is idempotent — safe to re-run.

CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- Active Tables (Tier 2)
-- ============================================================

-- Agents
CREATE TABLE IF NOT EXISTS agents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    role TEXT,
    model TEXT,
    capabilities JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Sprints
CREATE TABLE IF NOT EXISTS sprints (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sprint_number INTEGER UNIQUE NOT NULL,
    goal TEXT NOT NULL,
    status TEXT DEFAULT 'active',
    started_at TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ,
    retrospective JSONB
);

-- Decisions (shared consciousness — all agents see these)
CREATE TABLE IF NOT EXISTS decisions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sprint_id UUID REFERENCES sprints(id),
    agent_id UUID REFERENCES agents(id),
    summary TEXT NOT NULL,
    rationale TEXT,
    outcome TEXT,
    category TEXT,
    files_affected TEXT[],
    tags TEXT[],
    embedding VECTOR(2048),
    created_at TIMESTAMPTZ DEFAULT now(),
    superseded_by UUID REFERENCES decisions(id)
);

-- Lessons learned (shared consciousness — propagated to all agents)
CREATE TABLE IF NOT EXISTS lessons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    decision_id UUID REFERENCES decisions(id),
    agent_id UUID REFERENCES agents(id),
    category TEXT,
    summary TEXT NOT NULL,
    detail TEXT,
    code_right TEXT,
    code_wrong TEXT,
    times_referenced INTEGER DEFAULT 0,
    embedding VECTOR(2048),
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Team events (TELEPATHIC LINK — append-only event log)
CREATE TABLE IF NOT EXISTS team_events (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ DEFAULT now(),
    agent_name TEXT NOT NULL,
    event_type TEXT NOT NULL,
    summary TEXT NOT NULL,
    detail JSONB,
    files TEXT[],
    sprint_id UUID REFERENCES sprints(id),
    related_decision_id UUID REFERENCES decisions(id)
);

-- Agent sessions (per-agent work log)
CREATE TABLE IF NOT EXISTS agent_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id UUID REFERENCES agents(id),
    sprint_id UUID REFERENCES sprints(id),
    task TEXT,
    started_at TIMESTAMPTZ DEFAULT now(),
    ended_at TIMESTAMPTZ,
    files_modified TEXT[],
    outcome TEXT,
    handed_off_to UUID REFERENCES agents(id),
    notes JSONB
);

-- Knowledge chunks (embedded docs, patterns, skills)
CREATE TABLE IF NOT EXISTS knowledge (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    content TEXT NOT NULL,
    source_file TEXT,
    category TEXT,
    section TEXT,
    embedding VECTOR(2048),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes (ivfflat for vectors — pgvector hnsw has 2000-dim limit)
CREATE INDEX IF NOT EXISTS idx_decisions_embedding ON decisions USING ivfflat(embedding vector_cosine_ops) WITH (lists = 1);
CREATE INDEX IF NOT EXISTS idx_lessons_embedding ON lessons USING ivfflat(embedding vector_cosine_ops) WITH (lists = 1);
CREATE INDEX IF NOT EXISTS idx_knowledge_embedding ON knowledge USING ivfflat(embedding vector_cosine_ops) WITH (lists = 1);
CREATE INDEX IF NOT EXISTS idx_decisions_tags ON decisions USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_decisions_files ON decisions USING GIN(files_affected);
CREATE INDEX IF NOT EXISTS idx_events_ts ON team_events(ts);
CREATE INDEX IF NOT EXISTS idx_events_agent ON team_events(agent_name);
CREATE INDEX IF NOT EXISTS idx_events_type ON team_events(event_type);
CREATE INDEX IF NOT EXISTS idx_sessions_agent ON agent_sessions(agent_id);
CREATE INDEX IF NOT EXISTS idx_knowledge_source ON knowledge(source_file);
CREATE INDEX IF NOT EXISTS idx_knowledge_category ON knowledge(category);

-- ============================================================
-- DB-Primary Collaboration Tables
-- ============================================================

-- Messages (full chat history — every agent/human exchange)
CREATE TABLE IF NOT EXISTS messages (
    id BIGSERIAL PRIMARY KEY,
    session_id UUID REFERENCES agent_sessions(id),
    project TEXT NOT NULL DEFAULT 'myproject',
    agent_name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('human', 'agent', 'system')),
    content TEXT NOT NULL,
    metadata JSONB,
    embedding VECTOR(2048),
    ts TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
CREATE INDEX IF NOT EXISTS idx_messages_agent ON messages(agent_name);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts);
CREATE INDEX IF NOT EXISTS idx_messages_project ON messages(project);
CREATE INDEX IF NOT EXISTS idx_messages_embedding ON messages USING ivfflat(embedding vector_cosine_ops) WITH (lists = 1);

-- Handoffs (DB-native work transfers)
CREATE TABLE IF NOT EXISTS handoffs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project TEXT NOT NULL DEFAULT 'myproject',
    from_agent TEXT NOT NULL,
    from_role TEXT,
    to_role TEXT NOT NULL,
    priority TEXT DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high', 'urgent')),
    sprint_id UUID REFERENCES sprints(id),
    branch TEXT,
    summary TEXT NOT NULL,
    files_changed TEXT[],
    verification TEXT,
    next_steps TEXT,
    context TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'claimed', 'completed', 'archived')),
    claimed_by TEXT,
    claimed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_handoffs_status ON handoffs(status);
CREATE INDEX IF NOT EXISTS idx_handoffs_to_role ON handoffs(to_role);
CREATE INDEX IF NOT EXISTS idx_handoffs_project ON handoffs(project);

-- Tasks (DB-native task board)
CREATE TABLE IF NOT EXISTS tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project TEXT NOT NULL DEFAULT 'myproject',
    sprint_id UUID REFERENCES sprints(id),
    title TEXT NOT NULL,
    description TEXT,
    assigned_role TEXT,
    assigned_agent TEXT,
    status TEXT DEFAULT 'todo' CHECK (status IN ('todo', 'in_progress', 'review', 'done', 'blocked')),
    priority INTEGER DEFAULT 50,
    tags TEXT[],
    blocked_by UUID REFERENCES tasks(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned ON tasks(assigned_agent);
CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project);
CREATE INDEX IF NOT EXISTS idx_tasks_sprint ON tasks(sprint_id);

-- Add project column to existing tables for multi-project isolation
DO $$ BEGIN
    ALTER TABLE decisions ADD COLUMN IF NOT EXISTS agent_name TEXT;
    ALTER TABLE decisions ADD COLUMN IF NOT EXISTS project TEXT DEFAULT 'myproject';
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE lessons ADD COLUMN IF NOT EXISTS agent_name TEXT;
    ALTER TABLE lessons ADD COLUMN IF NOT EXISTS project TEXT DEFAULT 'myproject';
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE team_events ADD COLUMN IF NOT EXISTS project TEXT DEFAULT 'myproject';
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE agent_sessions ADD COLUMN IF NOT EXISTS project TEXT DEFAULT 'myproject';
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

-- ============================================================
-- Archive Tables (Tier 3: Cold Storage)
-- No embeddings — full text only, forever retention
-- ============================================================

CREATE TABLE IF NOT EXISTS archive_messages (
    id BIGINT PRIMARY KEY,
    session_id UUID,
    project TEXT,
    agent_name TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    metadata JSONB,
    ts TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_archive_messages_ts ON archive_messages(ts);
CREATE INDEX IF NOT EXISTS idx_archive_messages_agent ON archive_messages(agent_name);
CREATE INDEX IF NOT EXISTS idx_archive_messages_project ON archive_messages(project);

CREATE TABLE IF NOT EXISTS archive_events (
    id BIGINT PRIMARY KEY,
    ts TIMESTAMPTZ,
    agent_name TEXT NOT NULL,
    event_type TEXT NOT NULL,
    summary TEXT NOT NULL,
    detail JSONB,
    files TEXT[],
    project TEXT,
    sprint_id UUID
);
CREATE INDEX IF NOT EXISTS idx_archive_events_ts ON archive_events(ts);
CREATE INDEX IF NOT EXISTS idx_archive_events_agent ON archive_events(agent_name);

CREATE TABLE IF NOT EXISTS archive_decisions (
    id UUID PRIMARY KEY,
    sprint_id UUID,
    agent_name TEXT,
    summary TEXT NOT NULL,
    rationale TEXT,
    outcome TEXT,
    category TEXT,
    files_affected TEXT[],
    tags TEXT[],
    project TEXT,
    created_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS archive_lessons (
    id UUID PRIMARY KEY,
    agent_name TEXT,
    category TEXT,
    summary TEXT NOT NULL,
    detail TEXT,
    code_right TEXT,
    code_wrong TEXT,
    project TEXT,
    created_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS archive_handoffs (
    id UUID PRIMARY KEY,
    project TEXT,
    from_agent TEXT NOT NULL,
    to_role TEXT NOT NULL,
    priority TEXT,
    summary TEXT NOT NULL,
    files_changed TEXT[],
    status TEXT,
    created_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
);

-- ============================================================
-- Retention Configuration
-- ============================================================

CREATE TABLE IF NOT EXISTS retention_config (
    table_name TEXT PRIMARY KEY,
    tier2_days INTEGER NOT NULL DEFAULT 90,
    description TEXT
);

-- Seed default retention periods
INSERT INTO retention_config (table_name, tier2_days, description) VALUES
    ('messages', 90, 'Chat history — 90 days in pgvector, then archive'),
    ('team_events', 90, 'Team events — 90 days in pgvector, then archive'),
    ('decisions', 365, 'Decisions — 1 year in pgvector, then archive'),
    ('lessons', 365, 'Lessons — 1 year in pgvector, then archive'),
    ('handoffs', 30, 'Handoffs — 30 days in pgvector, then archive')
ON CONFLICT (table_name) DO NOTHING;
