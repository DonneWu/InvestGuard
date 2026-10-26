-- InvestGuard PostgreSQL bootstrap schema (proposed)
-- Version: 0.2
-- Scope: synthetic/sanitized senior-design prototype data only.
--
-- This script creates schemas and tables in the CURRENTLY CONNECTED database.
-- It does not create a database, database users, grants, or row-level security
-- policies. Run against a new/empty development database after team review.
-- Do not run against a database containing data: this is an initial schema,
-- not a migration or an upgrade script. It intentionally contains no DROP.

BEGIN;

-- Logical namespaces in one PostgreSQL database.
CREATE SCHEMA identity;
CREATE SCHEMA portfolio;
CREATE SCHEMA market;
CREATE SCHEMA research;
CREATE SCHEMA ops;

-- ---------------------------------------------------------------------------
-- 1. Users and roles
-- The identity provider owns authentication. Store its stable subject here;
-- never store passwords or provider secrets in this database.
-- ---------------------------------------------------------------------------

CREATE TABLE identity.app_users (
    user_id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    identity_subject        VARCHAR(255) NOT NULL UNIQUE,
    active_status           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE identity.roles (
    role_code               VARCHAR(50) PRIMARY KEY,
    description             TEXT
);

INSERT INTO identity.roles (role_code, description) VALUES
    ('adviser', 'Adviser access'),
    ('operations_admin', 'Operational administration'),
    ('compliance_viewer', 'Read-only review access');

CREATE TABLE identity.user_roles (
    user_id                 BIGINT NOT NULL
                            REFERENCES identity.app_users(user_id) ON DELETE RESTRICT,
    role_code               VARCHAR(50) NOT NULL
                            REFERENCES identity.roles(role_code) ON DELETE RESTRICT,
    assigned_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, role_code)
);

-- ---------------------------------------------------------------------------
-- 2. Client and portfolio ownership
-- Account belongs to one portfolio in this proposed model. Confirm this with
-- the team before implementation if portfolios may aggregate accounts.
-- ---------------------------------------------------------------------------

CREATE TABLE portfolio.clients (
    client_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    synthetic_label         VARCHAR(255) NOT NULL UNIQUE,
    status                  VARCHAR(20) NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'inactive')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE portfolio.client_access (
    client_access_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id               BIGINT NOT NULL
                            REFERENCES portfolio.clients(client_id) ON DELETE RESTRICT,
    user_id                 BIGINT NOT NULL
                            REFERENCES identity.app_users(user_id) ON DELETE RESTRICT,
    access_role             VARCHAR(50) NOT NULL
                            REFERENCES identity.roles(role_code) ON DELETE RESTRICT,
    granted_by_user_id      BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    granted_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at              TIMESTAMPTZ,
    CHECK (revoked_at IS NULL OR revoked_at >= granted_at)
);

CREATE UNIQUE INDEX client_access_active_uq
    ON portfolio.client_access (client_id, user_id)
    WHERE revoked_at IS NULL;

-- Stable security identity is separate from dated prices and fundamentals.
CREATE TABLE portfolio.securities (
    security_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticker                  VARCHAR(32) NOT NULL,
    security_name           VARCHAR(255),
    asset_type              VARCHAR(50) NOT NULL,
    exchange_code           VARCHAR(50),
    currency                CHAR(3),
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX securities_symbol_exchange_uq
    ON portfolio.securities (UPPER(ticker), COALESCE(UPPER(exchange_code), ''));

CREATE TABLE portfolio.portfolios (
    portfolio_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id               BIGINT NOT NULL
                            REFERENCES portfolio.clients(client_id) ON DELETE RESTRICT,
    portfolio_name          VARCHAR(255) NOT NULL,
    base_currency           CHAR(3) NOT NULL DEFAULT 'USD',
    benchmark_security_id   BIGINT
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (client_id, portfolio_name),
    UNIQUE (portfolio_id, client_id)
);

CREATE TABLE portfolio.accounts (
    account_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id            BIGINT NOT NULL,
    account_label           VARCHAR(255) NOT NULL,
    account_type            VARCHAR(50),
    currency                CHAR(3) NOT NULL DEFAULT 'USD',
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (portfolio_id)
        REFERENCES portfolio.portfolios(portfolio_id) ON DELETE RESTRICT,
    UNIQUE (portfolio_id, account_label),
    -- Required target for composite foreign keys that enforce account/portfolio match.
    UNIQUE (account_id, portfolio_id)
);

-- ---------------------------------------------------------------------------
-- 3. Import tracking and point-in-time position snapshots
-- A snapshot is the header for one dated position set; holdings are its rows.
-- ---------------------------------------------------------------------------

CREATE TABLE ops.ingestion_runs (
    ingestion_run_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_name             VARCHAR(255) NOT NULL,
    data_domain             VARCHAR(100) NOT NULL,
    started_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at            TIMESTAMPTZ,
    status                  VARCHAR(20) NOT NULL DEFAULT 'running'
                            CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
    rows_received           INTEGER NOT NULL DEFAULT 0 CHECK (rows_received >= 0),
    rows_accepted           INTEGER NOT NULL DEFAULT 0 CHECK (rows_accepted >= 0),
    rows_rejected           INTEGER NOT NULL DEFAULT 0 CHECK (rows_rejected >= 0),
    error_summary           TEXT,
    initiated_by_user_id    BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    CHECK (completed_at IS NULL OR completed_at >= started_at),
    CHECK (rows_accepted + rows_rejected <= rows_received)
);

CREATE TABLE portfolio.position_snapshots (
    snapshot_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id            BIGINT NOT NULL,
    account_id              BIGINT NOT NULL,
    as_of_time              TIMESTAMPTZ NOT NULL,
    received_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    source_name             VARCHAR(255) NOT NULL,
    source_file_name        TEXT,
    source_file_hash        VARCHAR(128),
    ingestion_run_id        BIGINT
                            REFERENCES ops.ingestion_runs(ingestion_run_id) ON DELETE RESTRICT,
    snapshot_status         VARCHAR(20) NOT NULL DEFAULT 'received'
                            CHECK (snapshot_status IN ('received', 'validated', 'partial', 'failed')),
    reconciliation_status   VARCHAR(20) NOT NULL DEFAULT 'pending'
                            CHECK (reconciliation_status IN ('pending', 'matched', 'exception')),
    rows_received           INTEGER NOT NULL DEFAULT 0 CHECK (rows_received >= 0),
    rows_accepted           INTEGER NOT NULL DEFAULT 0 CHECK (rows_accepted >= 0),
    rows_rejected           INTEGER NOT NULL DEFAULT 0 CHECK (rows_rejected >= 0),
    created_by_user_id      BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (account_id, portfolio_id)
        REFERENCES portfolio.accounts(account_id, portfolio_id) ON DELETE RESTRICT,
    CHECK (rows_accepted + rows_rejected <= rows_received)
);

CREATE UNIQUE INDEX position_snapshot_source_file_uq
    ON portfolio.position_snapshots (account_id, source_file_hash)
    WHERE source_file_hash IS NOT NULL;

CREATE TABLE portfolio.holdings (
    holding_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snapshot_id             BIGINT NOT NULL
                            REFERENCES portfolio.position_snapshots(snapshot_id) ON DELETE CASCADE,
    security_id             BIGINT NOT NULL
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    quantity                NUMERIC(24, 10) NOT NULL CHECK (quantity >= 0),
    quantity_unit           VARCHAR(20) NOT NULL DEFAULT 'shares',
    position_side           VARCHAR(10) NOT NULL DEFAULT 'long'
                            CHECK (position_side IN ('long', 'short')),
    currency                CHAR(3) NOT NULL DEFAULT 'USD',
    cost_basis_total        NUMERIC(20, 4) CHECK (cost_basis_total >= 0),
    average_cost_per_unit   NUMERIC(20, 6) CHECK (average_cost_per_unit >= 0),
    market_price            NUMERIC(20, 6) CHECK (market_price >= 0),
    market_value            NUMERIC(20, 4) CHECK (market_value >= 0),
    price_as_of             TIMESTAMPTZ,
    source_record_id        TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- Assumes one aggregated position per security per snapshot. Use a separate
    -- lots table or lot identifier if the prototype needs tax-lot detail.
    UNIQUE (snapshot_id, security_id)
);

-- ---------------------------------------------------------------------------
-- 4. Transactions and saved portfolio performance summaries
-- cash_amount convention: positive adds cash to the account; negative removes it.
-- quantity is an unsigned magnitude; transaction_type identifies the direction.
-- ---------------------------------------------------------------------------

CREATE TABLE portfolio.transactions (
    transaction_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id              BIGINT NOT NULL,
    portfolio_id            BIGINT NOT NULL,
    security_id             BIGINT
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    transaction_type        VARCHAR(30) NOT NULL
                            CHECK (transaction_type IN (
                                'BUY', 'SELL', 'DEPOSIT', 'WITHDRAWAL',
                                'DIVIDEND', 'FEE', 'SPLIT_ADJUSTMENT'
                            )),
    trade_date              DATE NOT NULL,
    settlement_date         DATE,
    quantity                NUMERIC(24, 10) CHECK (quantity >= 0),
    unit_price              NUMERIC(20, 6) CHECK (unit_price >= 0),
    fees                    NUMERIC(20, 4) NOT NULL DEFAULT 0 CHECK (fees >= 0),
    cash_amount             NUMERIC(20, 4) NOT NULL,
    currency                CHAR(3) NOT NULL DEFAULT 'USD',
    source_name             VARCHAR(255) NOT NULL,
    source_record_id        TEXT,
    ingestion_run_id        BIGINT
                            REFERENCES ops.ingestion_runs(ingestion_run_id) ON DELETE RESTRICT,
    validation_status       VARCHAR(20) NOT NULL DEFAULT 'accepted'
                            CHECK (validation_status IN ('pending', 'accepted', 'rejected')),
    notes                   TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (account_id, portfolio_id)
        REFERENCES portfolio.accounts(account_id, portfolio_id) ON DELETE RESTRICT,
    CHECK (settlement_date IS NULL OR settlement_date >= trade_date),
    CHECK (
        transaction_type NOT IN ('BUY', 'SELL')
        OR (
            security_id IS NOT NULL
            AND quantity IS NOT NULL
            AND quantity > 0
            AND unit_price IS NOT NULL
        )
    )
);

COMMENT ON COLUMN portfolio.transactions.cash_amount IS
    'Actual net cash movement: positive increases account cash; negative decreases it. Fees is informational and must not be subtracted twice.';

CREATE UNIQUE INDEX transactions_import_dedup_uq
    ON portfolio.transactions (account_id, source_name, source_record_id)
    WHERE source_record_id IS NOT NULL;

CREATE TABLE portfolio.performance_snapshots (
    performance_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id            BIGINT NOT NULL
                            REFERENCES portfolio.portfolios(portfolio_id) ON DELETE RESTRICT,
    as_of_date              DATE NOT NULL,
    market_value            NUMERIC(20, 4),
    cash_balance            NUMERIC(20, 4),
    open_cost_basis          NUMERIC(20, 4),
    realized_gain_loss      NUMERIC(20, 4),
    unrealized_gain_loss    NUMERIC(20, 4),
    total_return_value      NUMERIC(20, 4),
    total_return_pct        NUMERIC(12, 6),
    net_contributions       NUMERIC(20, 4),
    day_change_value        NUMERIC(20, 4),
    day_change_pct          NUMERIC(12, 6),
    benchmark_security_id   BIGINT
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    benchmark_return_pct    NUMERIC(12, 6),
    calculation_method      VARCHAR(100),
    calculation_version     VARCHAR(50) NOT NULL,
    snapshot_status         VARCHAR(20) NOT NULL DEFAULT 'complete'
                            CHECK (snapshot_status IN ('complete', 'partial', 'failed')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (portfolio_id, as_of_date, calculation_version)
);

-- ---------------------------------------------------------------------------
-- 5. Market data and fundamentals
-- Provider data is stored here; provider adapters/import jobs populate these tables.
-- ---------------------------------------------------------------------------

CREATE TABLE market.providers (
    provider_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider_code           VARCHAR(100) NOT NULL UNIQUE,
    display_name            VARCHAR(255) NOT NULL,
    provider_type           VARCHAR(50) NOT NULL,
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE market.quotes (
    quote_id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id             BIGINT NOT NULL
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    provider_id             BIGINT NOT NULL
                            REFERENCES market.providers(provider_id) ON DELETE RESTRICT,
    observed_at             TIMESTAMPTZ NOT NULL,
    price                   NUMERIC(20, 6) NOT NULL CHECK (price >= 0),
    currency                CHAR(3) NOT NULL,
    received_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    source_record_id        TEXT,
    ingestion_run_id        BIGINT
                            REFERENCES ops.ingestion_runs(ingestion_run_id) ON DELETE RESTRICT,
    UNIQUE (security_id, provider_id, observed_at)
);

CREATE TABLE market.daily_bars (
    daily_bar_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id             BIGINT NOT NULL
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    provider_id             BIGINT NOT NULL
                            REFERENCES market.providers(provider_id) ON DELETE RESTRICT,
    bar_date                DATE NOT NULL,
    open_price              NUMERIC(20, 6) CHECK (open_price >= 0),
    high_price              NUMERIC(20, 6) CHECK (high_price >= 0),
    low_price               NUMERIC(20, 6) CHECK (low_price >= 0),
    close_price             NUMERIC(20, 6) NOT NULL CHECK (close_price >= 0),
    adjusted_close          NUMERIC(20, 6) CHECK (adjusted_close >= 0),
    volume                  NUMERIC(24, 4) CHECK (volume >= 0),
    currency                CHAR(3) NOT NULL,
    received_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ingestion_run_id        BIGINT
                            REFERENCES ops.ingestion_runs(ingestion_run_id) ON DELETE RESTRICT,
    UNIQUE (security_id, provider_id, bar_date),
    CHECK (high_price IS NULL OR low_price IS NULL OR high_price >= low_price),
    CHECK (high_price IS NULL OR open_price IS NULL OR high_price >= open_price),
    CHECK (high_price IS NULL OR high_price >= close_price),
    CHECK (low_price IS NULL OR open_price IS NULL OR low_price <= open_price),
    CHECK (low_price IS NULL OR low_price <= close_price)
);

CREATE TABLE market.fundamental_observations (
    observation_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id             BIGINT NOT NULL
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    provider_id             BIGINT NOT NULL
                            REFERENCES market.providers(provider_id) ON DELETE RESTRICT,
    metric_code             VARCHAR(100) NOT NULL,
    value_numeric           NUMERIC(24, 8) NOT NULL,
    unit                    VARCHAR(50) NOT NULL,
    period_type             VARCHAR(30),
    period_start            DATE,
    period_end              DATE,
    reported_at             TIMESTAMPTZ,
    observed_at             TIMESTAMPTZ NOT NULL,
    received_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revision                VARCHAR(100),
    source_record_id        TEXT,
    ingestion_run_id        BIGINT
                            REFERENCES ops.ingestion_runs(ingestion_run_id) ON DELETE RESTRICT,
    CHECK (period_end IS NULL OR period_start IS NULL OR period_end >= period_start)
);

CREATE UNIQUE INDEX fundamental_source_record_uq
    ON market.fundamental_observations
       (security_id, provider_id, metric_code, source_record_id)
    WHERE source_record_id IS NOT NULL;

CREATE INDEX fundamental_observations_lookup_idx
    ON market.fundamental_observations
       (security_id, metric_code, period_end DESC, observed_at DESC);

-- ---------------------------------------------------------------------------
-- 6. Watchlists and derived research outputs
-- Calculated outputs retain their version and input references for explanation.
-- They are decision-support research, not autonomous advice or trade execution.
-- ---------------------------------------------------------------------------

CREATE TABLE research.watchlists (
    watchlist_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    list_scope              VARCHAR(20) NOT NULL
                            CHECK (list_scope IN ('adviser_global', 'client')),
    client_id               BIGINT
                            REFERENCES portfolio.clients(client_id) ON DELETE RESTRICT,
    name                    VARCHAR(255) NOT NULL,
    created_by_user_id      BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (
        (list_scope = 'adviser_global' AND client_id IS NULL)
        OR (list_scope = 'client' AND client_id IS NOT NULL)
    )
);

CREATE TABLE research.watchlist_entries (
    watchlist_entry_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    watchlist_id            BIGINT NOT NULL
                            REFERENCES research.watchlists(watchlist_id) ON DELETE CASCADE,
    security_id             BIGINT NOT NULL
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    thesis                  TEXT,
    target_entry_price      NUMERIC(20, 6) CHECK (target_entry_price >= 0),
    priority_rank           INTEGER CHECK (priority_rank IS NULL OR priority_rank >= 0),
    created_by_user_id      BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    removed_at              TIMESTAMPTZ
);

CREATE UNIQUE INDEX watchlist_entries_active_uq
    ON research.watchlist_entries (watchlist_id, security_id)
    WHERE removed_at IS NULL;

CREATE TABLE research.calculated_metrics (
    calculated_metric_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id             BIGINT NOT NULL
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    metric_code             VARCHAR(100) NOT NULL,
    metric_value            NUMERIC(24, 8),
    unit                    VARCHAR(50) NOT NULL,
    as_of_time              TIMESTAMPTZ NOT NULL,
    formula_version         VARCHAR(50) NOT NULL,
    input_references        JSONB NOT NULL DEFAULT '[]'::JSONB,
    calculated_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    data_freshness          VARCHAR(30),
    UNIQUE (security_id, metric_code, as_of_time, formula_version)
);

CREATE TABLE research.signals (
    signal_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id             BIGINT NOT NULL
                            REFERENCES portfolio.securities(security_id) ON DELETE RESTRICT,
    portfolio_id            BIGINT
                            REFERENCES portfolio.portfolios(portfolio_id) ON DELETE RESTRICT,
    signal_code             VARCHAR(100) NOT NULL,
    signal_state            VARCHAR(50) NOT NULL,
    reason                  TEXT,
    formula_version         VARCHAR(50) NOT NULL,
    input_references        JSONB NOT NULL DEFAULT '[]'::JSONB,
    calculated_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    review_status           VARCHAR(30)
);

CREATE UNIQUE INDEX signals_global_dedup_uq
    ON research.signals (security_id, signal_code, calculated_at, formula_version)
    WHERE portfolio_id IS NULL;
CREATE UNIQUE INDEX signals_portfolio_dedup_uq
    ON research.signals (security_id, portfolio_id, signal_code, calculated_at, formula_version)
    WHERE portfolio_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 7. Data-quality, audit, and optional recovery evidence
-- These are separate tables because they describe different kinds of events.
-- ---------------------------------------------------------------------------

CREATE TABLE ops.data_quality_exceptions (
    exception_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingestion_run_id        BIGINT
                            REFERENCES ops.ingestion_runs(ingestion_run_id) ON DELETE RESTRICT,
    data_domain             VARCHAR(100) NOT NULL,
    source_row_number       INTEGER CHECK (source_row_number IS NULL OR source_row_number > 0),
    object_reference        TEXT,
    field_name              VARCHAR(100),
    rule_code               VARCHAR(100) NOT NULL,
    severity                VARCHAR(20) NOT NULL
                            CHECK (severity IN ('info', 'warning', 'error', 'critical')),
    message                 TEXT NOT NULL,
    disposition             VARCHAR(30) NOT NULL DEFAULT 'open'
                            CHECK (disposition IN ('open', 'accepted', 'corrected', 'rejected', 'resolved')),
    resolved_by_user_id     BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    resolved_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE ops.audit_events (
    audit_event_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_user_id           BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    actor_type              VARCHAR(20) NOT NULL DEFAULT 'user'
                            CHECK (actor_type IN ('user', 'system')),
    occurred_at             TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    action                  VARCHAR(100) NOT NULL,
    object_schema           VARCHAR(100) NOT NULL,
    object_table            VARCHAR(100) NOT NULL,
    object_id               TEXT,
    result                  VARCHAR(30) NOT NULL,
    correlation_id          UUID,
    details                 JSONB NOT NULL DEFAULT '{}'::JSONB,
    CHECK (
        (actor_type = 'system' AND actor_user_id IS NULL)
        OR (actor_type = 'user' AND actor_user_id IS NOT NULL)
    )
);

CREATE TABLE ops.backup_restore_runs (
    backup_restore_run_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    environment_name        VARCHAR(50) NOT NULL,
    operation               VARCHAR(20) NOT NULL CHECK (operation IN ('backup', 'restore')),
    started_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at            TIMESTAMPTZ,
    status                  VARCHAR(20) NOT NULL
                            CHECK (status IN ('running', 'succeeded', 'failed')),
    artifact_reference      TEXT,
    validation_summary      TEXT,
    performed_by_user_id    BIGINT
                            REFERENCES identity.app_users(user_id) ON DELETE SET NULL,
    CHECK (completed_at IS NULL OR completed_at >= started_at)
);

-- ---------------------------------------------------------------------------
-- 8. Indexes for common joins and time-based reads
-- PostgreSQL does not automatically index the referencing side of every FK.
-- ---------------------------------------------------------------------------

CREATE INDEX client_access_user_idx
    ON portfolio.client_access (user_id, client_id)
    WHERE revoked_at IS NULL;
CREATE INDEX portfolios_client_idx
    ON portfolio.portfolios (client_id);
CREATE INDEX accounts_portfolio_idx
    ON portfolio.accounts (portfolio_id);
CREATE INDEX snapshots_account_time_idx
    ON portfolio.position_snapshots (account_id, as_of_time DESC);
CREATE INDEX snapshots_portfolio_time_idx
    ON portfolio.position_snapshots (portfolio_id, as_of_time DESC);
CREATE INDEX holdings_security_idx
    ON portfolio.holdings (security_id);
CREATE INDEX transactions_account_date_idx
    ON portfolio.transactions (account_id, trade_date DESC);
CREATE INDEX ingestion_runs_status_time_idx
    ON ops.ingestion_runs (status, started_at DESC);
CREATE INDEX quotes_security_time_idx
    ON market.quotes (security_id, observed_at DESC);
CREATE INDEX daily_bars_security_date_idx
    ON market.daily_bars (security_id, bar_date DESC);
CREATE INDEX audit_events_object_time_idx
    ON ops.audit_events (object_schema, object_table, object_id, occurred_at DESC);

-- RLS policies and GRANT statements are intentionally not included. They depend
-- on the selected identity provider, database connection pattern, and agreed
-- client-access model. Design and test those policies before using real data.

COMMIT;