-- UseTrace Studio, PostgreSQL 16. Apply once to an empty database.
-- Identifiers and timestamps are supplied by the application in one transaction.
BEGIN;

CREATE TABLE user_accounts (
    id uuid PRIMARY KEY,
    oidc_subject varchar(255) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL,
    CONSTRAINT user_accounts_oidc_subject_nonempty CHECK (btrim(oidc_subject) <> '')
);

CREATE TABLE projects (
    id uuid PRIMARY KEY,
    name varchar(200) NOT NULL,
    project_revision bigint NOT NULL DEFAULT 0,
    graph_revision bigint NOT NULL DEFAULT 0,
    next_requirement_number bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CONSTRAINT projects_name_nonempty CHECK (btrim(name) <> ''),
    CONSTRAINT projects_project_revision_nonnegative CHECK (project_revision >= 0),
    CONSTRAINT projects_graph_revision_nonnegative CHECK (graph_revision >= 0),
    CONSTRAINT projects_next_requirement_number_range CHECK (next_requirement_number BETWEEN 1 AND 100000000)
);

CREATE TABLE project_memberships (
    project_id uuid NOT NULL REFERENCES projects(id),
    user_id uuid NOT NULL REFERENCES user_accounts(id),
    joined_at timestamptz NOT NULL,
    PRIMARY KEY (project_id, user_id)
);

CREATE TABLE membership_permissions (
    project_id uuid NOT NULL,
    user_id uuid NOT NULL,
    permission varchar(10) NOT NULL,
    PRIMARY KEY (project_id, user_id, permission),
    FOREIGN KEY (project_id, user_id) REFERENCES project_memberships(project_id, user_id),
    CONSTRAINT membership_permissions_value CHECK (permission IN ('read', 'write', 'qa', 'admin'))
);

CREATE TABLE requirements (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id),
    code varchar(12) NOT NULL,
    title varchar(200) NOT NULL,
    statement text NOT NULL,
    type varchar(20) NOT NULL,
    status varchar(12) NOT NULL,
    version integer NOT NULL,
    needs_review boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE (project_id, id),
    UNIQUE (project_id, code),
    CONSTRAINT requirements_code_pattern CHECK (code ~ '^REQ-[0-9]{4,8}$'),
    CONSTRAINT requirements_title_length CHECK (length(btrim(title)) BETWEEN 1 AND 200),
    CONSTRAINT requirements_statement_length CHECK (length(btrim(statement)) BETWEEN 1 AND 10000),
    CONSTRAINT requirements_type_value CHECK (type IN ('functional', 'nonfunctional')),
    CONSTRAINT requirements_status_value CHECK (status IN ('draft', 'approved', 'archived')),
    CONSTRAINT requirements_version_positive CHECK (version > 0)
);

CREATE TABLE requirement_revisions (
    id uuid PRIMARY KEY,
    requirement_id uuid NOT NULL REFERENCES requirements(id),
    version integer NOT NULL,
    title varchar(200) NOT NULL,
    statement text NOT NULL,
    type varchar(20) NOT NULL,
    status varchar(12) NOT NULL,
    author_id uuid NOT NULL REFERENCES user_accounts(id),
    changed_at timestamptz NOT NULL,
    UNIQUE (requirement_id, version),
    CONSTRAINT requirement_revisions_version_positive CHECK (version > 0),
    CONSTRAINT requirement_revisions_title_length CHECK (length(btrim(title)) BETWEEN 1 AND 200),
    CONSTRAINT requirement_revisions_statement_length CHECK (length(btrim(statement)) BETWEEN 1 AND 10000),
    CONSTRAINT requirement_revisions_type_value CHECK (type IN ('functional', 'nonfunctional')),
    CONSTRAINT requirement_revisions_status_value CHECK (status IN ('draft', 'approved', 'archived'))
);

CREATE TABLE requirement_dependencies (
    id uuid NOT NULL UNIQUE,
    project_id uuid NOT NULL REFERENCES projects(id),
    source_id uuid NOT NULL,
    target_id uuid NOT NULL,
    created_at timestamptz NOT NULL,
    PRIMARY KEY (project_id, source_id, target_id),
    FOREIGN KEY (project_id, source_id) REFERENCES requirements(project_id, id),
    FOREIGN KEY (project_id, target_id) REFERENCES requirements(project_id, id),
    CONSTRAINT requirement_dependencies_no_self_loop CHECK (source_id <> target_id)
);

CREATE TABLE uml_models (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id),
    name varchar(200) NOT NULL,
    version integer NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE (project_id, id),
    CONSTRAINT uml_models_name_nonempty CHECK (btrim(name) <> ''),
    CONSTRAINT uml_models_version_positive CHECK (version > 0)
);

CREATE TABLE uml_classes (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL,
    model_id uuid NOT NULL,
    stable_code varchar(10) NOT NULL,
    name varchar(200) NOT NULL,
    UNIQUE (model_id, id),
    UNIQUE (project_id, id),
    UNIQUE (model_id, stable_code),
    FOREIGN KEY (project_id, model_id) REFERENCES uml_models(project_id, id),
    CONSTRAINT uml_classes_code_pattern CHECK (stable_code ~ '^C_[0-9]{1,8}$'),
    CONSTRAINT uml_classes_name_nonempty CHECK (btrim(name) <> '')
);

CREATE TABLE uml_attributes (
    id uuid PRIMARY KEY,
    class_id uuid NOT NULL REFERENCES uml_classes(id) ON DELETE CASCADE,
    name varchar(100) NOT NULL,
    data_type varchar(10) NOT NULL,
    position integer NOT NULL,
    UNIQUE (class_id, name),
    UNIQUE (class_id, position),
    CONSTRAINT uml_attributes_name_nonempty CHECK (btrim(name) <> ''),
    CONSTRAINT uml_attributes_type_value CHECK (data_type IN ('string', 'int', 'bool')),
    CONSTRAINT uml_attributes_position_nonnegative CHECK (position >= 0)
);

CREATE TABLE uml_associations (
    id uuid PRIMARY KEY,
    model_id uuid NOT NULL REFERENCES uml_models(id),
    source_class_id uuid NOT NULL,
    target_class_id uuid NOT NULL,
    UNIQUE (model_id, source_class_id, target_class_id),
    FOREIGN KEY (model_id, source_class_id) REFERENCES uml_classes(model_id, id) ON DELETE CASCADE,
    FOREIGN KEY (model_id, target_class_id) REFERENCES uml_classes(model_id, id) ON DELETE CASCADE
);

CREATE TABLE uml_class_requirements (
    project_id uuid NOT NULL,
    class_id uuid NOT NULL,
    requirement_id uuid NOT NULL,
    PRIMARY KEY (project_id, class_id, requirement_id),
    FOREIGN KEY (project_id, class_id) REFERENCES uml_classes(project_id, id) ON DELETE CASCADE,
    FOREIGN KEY (project_id, requirement_id) REFERENCES requirements(project_id, id)
);

CREATE TABLE wbs_items (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id),
    parent_id uuid,
    title varchar(200) NOT NULL,
    version integer NOT NULL DEFAULT 1,
    estimate_hours numeric(7,1),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE (project_id, id),
    FOREIGN KEY (project_id, parent_id) REFERENCES wbs_items(project_id, id),
    CONSTRAINT wbs_items_no_self_parent CHECK (parent_id IS NULL OR id <> parent_id),
    CONSTRAINT wbs_items_title_nonempty CHECK (btrim(title) <> ''),
    CONSTRAINT wbs_items_version_positive CHECK (version > 0),
    CONSTRAINT wbs_items_estimate_positive CHECK (estimate_hours IS NULL OR estimate_hours > 0)
);

CREATE TABLE test_cases (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id),
    title varchar(200) NOT NULL,
    steps text NOT NULL,
    expected_result text NOT NULL,
    status varchar(12) NOT NULL,
    version integer NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE (project_id, id),
    CONSTRAINT test_cases_title_nonempty CHECK (btrim(title) <> ''),
    CONSTRAINT test_cases_steps_nonempty CHECK (btrim(steps) <> ''),
    CONSTRAINT test_cases_expected_result_nonempty CHECK (btrim(expected_result) <> ''),
    CONSTRAINT test_cases_status_value CHECK (status IN ('draft', 'active', 'archived')),
    CONSTRAINT test_cases_version_positive CHECK (version > 0)
);

CREATE TABLE test_coverage (
    project_id uuid NOT NULL,
    test_case_id uuid NOT NULL,
    requirement_id uuid NOT NULL,
    linked_at timestamptz NOT NULL,
    PRIMARY KEY (project_id, test_case_id, requirement_id),
    FOREIGN KEY (project_id, test_case_id) REFERENCES test_cases(project_id, id),
    FOREIGN KEY (project_id, requirement_id) REFERENCES requirements(project_id, id)
);

CREATE TABLE qa_tasks (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL,
    requirement_id uuid NOT NULL,
    requirement_version integer NOT NULL,
    title varchar(200) NOT NULL,
    status varchar(20) NOT NULL,
    source varchar(10) NOT NULL,
    version integer NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    FOREIGN KEY (project_id, requirement_id) REFERENCES requirements(project_id, id),
    FOREIGN KEY (requirement_id, requirement_version) REFERENCES requirement_revisions(requirement_id, version),
    CONSTRAINT qa_tasks_title_nonempty CHECK (btrim(title) <> ''),
    CONSTRAINT qa_tasks_status_value CHECK (status IN ('todo', 'in_progress', 'done', 'cancelled')),
    CONSTRAINT qa_tasks_source_value CHECK (source IN ('auto', 'manual')),
    CONSTRAINT qa_tasks_version_positive CHECK (version > 0)
);

CREATE TABLE audit_events (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id),
    project_revision bigint NOT NULL,
    actor_id uuid REFERENCES user_accounts(id),
    entity_type varchar(30) NOT NULL,
    entity_id uuid NOT NULL,
    entity_version integer,
    operation varchar(30) NOT NULL,
    result varchar(10) NOT NULL,
    changed_fields jsonb NOT NULL,
    occurred_at timestamptz NOT NULL,
    UNIQUE (project_id, project_revision),
    CONSTRAINT audit_events_project_revision_positive CHECK (project_revision > 0),
    CONSTRAINT audit_events_entity_type_nonempty CHECK (btrim(entity_type) <> ''),
    CONSTRAINT audit_events_operation_nonempty CHECK (btrim(operation) <> ''),
    CONSTRAINT audit_events_result_success CHECK (result = 'success'),
    CONSTRAINT audit_events_changed_fields_array CHECK (jsonb_typeof(changed_fields) = 'array'),
    CONSTRAINT audit_events_entity_version_positive CHECK (entity_version IS NULL OR entity_version > 0)
);

-- Access patterns described in section 2.4; PK/UNIQUE create their own B-tree indexes.
CREATE INDEX requirements_project_status_idx ON requirements(project_id, status);
CREATE INDEX requirement_dependencies_project_target_idx ON requirement_dependencies(project_id, target_id);
CREATE INDEX uml_associations_model_target_idx ON uml_associations(model_id, target_class_id);
CREATE INDEX uml_class_requirements_project_requirement_idx ON uml_class_requirements(project_id, requirement_id);
CREATE INDEX wbs_items_project_parent_idx ON wbs_items(project_id, parent_id);
CREATE INDEX test_coverage_project_requirement_test_idx ON test_coverage(project_id, requirement_id, test_case_id);
CREATE UNIQUE INDEX qa_tasks_open_auto_unique_idx ON qa_tasks(requirement_id, requirement_version)
    WHERE source = 'auto' AND status IN ('todo', 'in_progress');
CREATE INDEX qa_tasks_project_status_idx ON qa_tasks(project_id, status);
CREATE INDEX audit_events_project_occurred_idx ON audit_events(project_id, occurred_at);

-- Snapshots and committed audit events are append-only, even for an application role
-- accidentally granted UPDATE/DELETE. A database owner can still change the schema.
CREATE FUNCTION reject_immutable_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'immutable table % cannot be updated or deleted', TG_TABLE_NAME
        USING ERRCODE = '55000';
END;
$$;
CREATE TRIGGER requirement_revisions_immutable
    BEFORE UPDATE OR DELETE ON requirement_revisions
    FOR EACH ROW EXECUTE FUNCTION reject_immutable_change();
CREATE TRIGGER audit_events_immutable
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION reject_immutable_change();

COMMIT;
