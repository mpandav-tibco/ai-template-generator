-- BWCE AI Generator - Generation Registry Schema
-- PostgreSQL database: agentforge

CREATE TABLE IF NOT EXISTS generation_log (
    id              SERIAL PRIMARY KEY,
    generation_id   VARCHAR(36)  NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
    repo_name       VARCHAR(100) NOT NULL,
    source_system   VARCHAR(50)  NOT NULL,
    target_system   VARCHAR(50)  NOT NULL,
    business_object VARCHAR(100) NOT NULL,
    interface_type  VARCHAR(10)  NOT NULL CHECK (interface_type IN ('pub', 'sub', 'service')),
    template_type   VARCHAR(200),
    template_name   VARCHAR(200),
    cdm             BOOLEAN      DEFAULT FALSE,
    need_secret     BOOLEAN      DEFAULT FALSE,
    interface_id    VARCHAR(50)  DEFAULT 'NA',
    scenario_id     VARCHAR(20)  DEFAULT '1234',
    bitbucket_project VARCHAR(50),
    env             VARCHAR(50)  DEFAULT 'DEV',
    email           VARCHAR(200),
    k8s_domain      VARCHAR(50)  DEFAULT 'cite',
    country_code    VARCHAR(10)  DEFAULT 'NA',
    unique_id       VARCHAR(50)  DEFAULT 'NA',
    status          VARCHAR(20)  DEFAULT 'GENERATED' CHECK (status IN ('GENERATED', 'FAILED', 'DUPLICATE')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  DEFAULT NOW()
);

-- Idempotent migration: add columns to pre-existing generation_log tables
ALTER TABLE generation_log
    ADD COLUMN IF NOT EXISTS template_name VARCHAR(200),
    ADD COLUMN IF NOT EXISTS need_secret   BOOLEAN     DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS country_code  VARCHAR(10) DEFAULT 'NA',
    ADD COLUMN IF NOT EXISTS unique_id     VARCHAR(50) DEFAULT 'NA';

CREATE INDEX IF NOT EXISTS idx_generation_repo_name ON generation_log(repo_name);
CREATE INDEX IF NOT EXISTS idx_generation_created_at ON generation_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_generation_source_target ON generation_log(source_system, target_system);

-- Duplicate detection view
CREATE OR REPLACE VIEW v_duplicate_check AS
SELECT repo_name, COUNT(*) as count, MAX(created_at) as last_generated
FROM generation_log
GROUP BY repo_name
HAVING COUNT(*) > 1;

-- Generation stats view
CREATE OR REPLACE VIEW v_generation_stats AS
SELECT
    source_system,
    target_system,
    interface_type,
    COUNT(*) as total_generated,
    MAX(created_at) as last_generated
FROM generation_log
WHERE status = 'GENERATED'
GROUP BY source_system, target_system, interface_type
ORDER BY total_generated DESC;

-- Conversational session store (replaces the in-memory #shareddata session map
-- so chat sessions survive restarts and can be shared across instances).
CREATE TABLE IF NOT EXISTS chat_session (
    session_id        VARCHAR(64)  PRIMARY KEY,
    status            VARCHAR(20)  DEFAULT 'active',
    message           TEXT         DEFAULT '',
    source_system     VARCHAR(50)  DEFAULT '',
    target_system     VARCHAR(50)  DEFAULT '',
    business_object   VARCHAR(100) DEFAULT '',
    interface_type    VARCHAR(20)  DEFAULT '',
    template_type     VARCHAR(200) DEFAULT '',
    cdm               VARCHAR(10)  DEFAULT '',
    interface_id      VARCHAR(50)  DEFAULT '',
    scenario_id       VARCHAR(20)  DEFAULT '',
    bitbucket_project VARCHAR(50)  DEFAULT '',
    email             VARCHAR(200) DEFAULT '',
    env               VARCHAR(50)  DEFAULT '',
    k8s_domain        VARCHAR(50)  DEFAULT '',
    country_code      VARCHAR(10)  DEFAULT '',
    unique_id         VARCHAR(50)  DEFAULT '',
    missing_fields    TEXT         DEFAULT '[]',
    ready_to_generate BOOLEAN      DEFAULT FALSE,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chat_session_updated ON chat_session(updated_at DESC);
