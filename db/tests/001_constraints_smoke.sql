-- Run against a disposable PostgreSQL 16 database after 001_initial_schema.sql.
-- All inserted test data is rolled back at the end; any unexpected result aborts psql.
BEGIN;

DO $test$
DECLARE
    rejected boolean;
BEGIN
    INSERT INTO user_accounts (id, oidc_subject, created_at)
    VALUES ('00000000-0000-4000-8000-000000000001', 'test-user', now());
    INSERT INTO projects (id, name, created_at, updated_at)
    VALUES
      ('00000000-0000-4000-8000-000000000011', 'Test project A', now(), now()),
      ('00000000-0000-4000-8000-000000000012', 'Test project B', now(), now());
    INSERT INTO project_memberships (project_id, user_id, joined_at)
    VALUES ('00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001', now());
    INSERT INTO membership_permissions (project_id, user_id, permission)
    VALUES ('00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001', 'write');

    INSERT INTO requirements
      (id, project_id, code, title, statement, type, status, version, created_at, updated_at)
    VALUES
      ('00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000011', 'REQ-0001', 'First', 'The system shall save a requirement.', 'functional', 'draft', 1, now(), now()),
      ('00000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000011', 'REQ-0002', 'Second', 'The system shall record impact.', 'functional', 'approved', 1, now(), now()),
      ('00000000-0000-4000-8000-000000000103', '00000000-0000-4000-8000-000000000012', 'REQ-0001', 'Other', 'The system shall isolate projects.', 'functional', 'draft', 1, now(), now());
    INSERT INTO requirement_revisions
      (id, requirement_id, version, title, statement, type, status, author_id, changed_at)
    VALUES ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 1, 'First', 'The system shall save a requirement.', 'functional', 'draft', '00000000-0000-4000-8000-000000000001', now());
    INSERT INTO requirement_dependencies (id, project_id, source_id, target_id, created_at)
    VALUES ('00000000-0000-4000-8000-000000000301', '00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000102', now());
    INSERT INTO qa_tasks
      (id, project_id, requirement_id, requirement_version, title, status, source, created_at, updated_at)
    VALUES ('00000000-0000-4000-8000-000000000401', '00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000101', 1, 'Review', 'todo', 'auto', now(), now());
    INSERT INTO audit_events
      (id, project_id, project_revision, actor_id, entity_type, entity_id, entity_version, operation, result, changed_fields, occurred_at)
    VALUES ('00000000-0000-4000-8000-000000000501', '00000000-0000-4000-8000-000000000011', 1, '00000000-0000-4000-8000-000000000001', 'requirement', '00000000-0000-4000-8000-000000000101', 1, 'create', 'success', '["title"]'::jsonb, now());

    rejected := false;
    BEGIN
        INSERT INTO user_accounts (id, oidc_subject, created_at)
        VALUES ('00000000-0000-4000-8000-000000000001', 'another-subject', now());
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'user_accounts primary key was not enforced'; END IF;

    rejected := false;
    BEGIN
        INSERT INTO project_memberships (project_id, user_id, joined_at)
        VALUES ('00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000099', now());
    EXCEPTION WHEN foreign_key_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'membership user FK was not enforced'; END IF;

    rejected := false;
    BEGIN
        INSERT INTO requirements
          (id, project_id, code, title, statement, type, status, version, created_at, updated_at)
        VALUES ('00000000-0000-4000-8000-000000000104', '00000000-0000-4000-8000-000000000011', 'REQ-0001', 'Duplicate', 'The system shall reject duplicates.', 'functional', 'draft', 1, now(), now());
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'UNIQUE(project_id, code) was not enforced'; END IF;

    rejected := false;
    BEGIN
        UPDATE requirements SET status = 'completed' WHERE id = '00000000-0000-4000-8000-000000000101';
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'requirement status CHECK was not enforced'; END IF;

    rejected := false;
    BEGIN
        INSERT INTO requirement_dependencies (id, project_id, source_id, target_id, created_at)
        VALUES ('00000000-0000-4000-8000-000000000302', '00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000103', now());
    EXCEPTION WHEN foreign_key_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'cross-project dependency FK was not enforced'; END IF;

    rejected := false;
    BEGIN
        INSERT INTO requirement_dependencies (id, project_id, source_id, target_id, created_at)
        VALUES ('00000000-0000-4000-8000-000000000303', '00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000101', now());
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'self-loop CHECK was not enforced'; END IF;

    rejected := false;
    BEGIN
        INSERT INTO qa_tasks
          (id, project_id, requirement_id, requirement_version, title, status, source, created_at, updated_at)
        VALUES ('00000000-0000-4000-8000-000000000402', '00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000101', 1, 'Duplicate auto task', 'in_progress', 'auto', now(), now());
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'open automatic QA task uniqueness was not enforced'; END IF;

    rejected := false;
    BEGIN
        UPDATE requirement_revisions SET title = 'Changed' WHERE id = '00000000-0000-4000-8000-000000000201';
    EXCEPTION WHEN SQLSTATE '55000' THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'revision immutability was not enforced'; END IF;

    rejected := false;
    BEGIN
        DELETE FROM audit_events WHERE id = '00000000-0000-4000-8000-000000000501';
    EXCEPTION WHEN SQLSTATE '55000' THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'audit immutability was not enforced'; END IF;

    RAISE NOTICE 'PASS: accepted rows, UNIQUE, CHECK, composite FK, partial UNIQUE, append-only triggers';
END;
$test$;

ROLLBACK;
