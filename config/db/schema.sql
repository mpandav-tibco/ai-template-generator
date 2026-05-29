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
    cdm             BOOLEAN      DEFAULT FALSE,
    interface_id    VARCHAR(50)  DEFAULT 'NA',
    scenario_id     VARCHAR(20)  DEFAULT '1234',
    bitbucket_project VARCHAR(50),
    env             VARCHAR(50)  DEFAULT 'DEV',
    email           VARCHAR(200),
    k8s_domain      VARCHAR(50)  DEFAULT 'cite',
    status          VARCHAR(20)  DEFAULT 'GENERATED' CHECK (status IN ('GENERATED', 'FAILED', 'DUPLICATE')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  DEFAULT NOW()
);

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
