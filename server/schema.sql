CREATE TABLE IF NOT EXISTS schema_versions(version integer PRIMARY KEY);
CREATE TABLE IF NOT EXISTS provinces (
    id integer PRIMARY KEY CHECK(id > 0 AND id < 16777216),
    kind text NOT NULL CHECK(kind IN ('land','sea','lake')),
    name text NOT NULL,
    center jsonb NOT NULL, bbox jsonb NOT NULL,
    area bigint NOT NULL CHECK(area > 0), seed_area bigint NOT NULL,
    population bigint CHECK(population >= 0),
    development numeric CHECK(development >= 0)
);
CREATE TABLE IF NOT EXISTS map_categories (
    layer text NOT NULL CHECK(layer IN ('states','races','religions','resources','trade','climate')),
    id integer NOT NULL, name text NOT NULL,
    color text NOT NULL CHECK(color ~ '^#[0-9A-Fa-f]{6}$'),
    PRIMARY KEY(layer,id)
);
CREATE TABLE IF NOT EXISTS province_values (
    province_id integer NOT NULL REFERENCES provinces(id) ON DELETE CASCADE,
    layer text NOT NULL, category_id integer NOT NULL,
    PRIMARY KEY(province_id,layer),
    FOREIGN KEY(layer,category_id) REFERENCES map_categories(layer,id)
);
CREATE TABLE IF NOT EXISTS accounts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE, nickname text NOT NULL,
    password_hash text NOT NULL,
    role text NOT NULL DEFAULT 'player' CHECK(role IN ('player','admin')),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS sessions (
    token_hash text PRIMARY KEY, account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_account_idx ON sessions(account_id);
CREATE TABLE IF NOT EXISTS password_resets (
    token_hash text PRIMARY KEY, account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS user_preferences (
    account_id bigint PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    settings jsonb NOT NULL DEFAULT '{}'
);
INSERT INTO schema_versions VALUES(1) ON CONFLICT DO NOTHING;
