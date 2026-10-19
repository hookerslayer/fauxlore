CREATE TABLE IF NOT EXISTS schema_versions(version integer PRIMARY KEY);
CREATE TABLE IF NOT EXISTS provinces (
    id integer PRIMARY KEY CHECK(id > 0 AND id < 16777216),
    kind text NOT NULL CHECK(kind IN ('land','sea','lake')),
    name text NOT NULL,
    center jsonb NOT NULL, bbox jsonb NOT NULL,
    area bigint NOT NULL CHECK(area > 0), seed_area bigint NOT NULL,
    population bigint NOT NULL DEFAULT 0 CHECK(population >= 0),
    development integer CHECK(development >= 0),
    province_type text NOT NULL DEFAULT 'Нейтральная',
    courts integer NOT NULL DEFAULT 0 CHECK(courts >= 0),
    control text,
    has_capital_marker boolean NOT NULL DEFAULT false,
    has_city_marker boolean NOT NULL DEFAULT false,
    taxes numeric,
    production jsonb,
    warehouse jsonb,
    tension numeric
);
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS province_type text NOT NULL DEFAULT 'Нейтральная';
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS courts integer NOT NULL DEFAULT 0 CHECK(courts >= 0);
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS control text;
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS has_capital_marker boolean NOT NULL DEFAULT false;
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS has_city_marker boolean NOT NULL DEFAULT false;
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS taxes numeric;
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS production jsonb;
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS warehouse jsonb;
ALTER TABLE provinces ADD COLUMN IF NOT EXISTS tension numeric;
ALTER TABLE provinces ALTER COLUMN development TYPE integer USING round(development)::integer;
UPDATE provinces SET population=courts*4 WHERE population IS DISTINCT FROM courts*4;
ALTER TABLE provinces ALTER COLUMN population SET DEFAULT 0;
ALTER TABLE provinces ALTER COLUMN population SET NOT NULL;
ALTER TABLE provinces DROP CONSTRAINT IF EXISTS provinces_type_check;
ALTER TABLE provinces ADD CONSTRAINT provinces_type_check
    CHECK(province_type IN ('Столица','Город','Регион','Колония','Нейтральная'));
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
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS reputation integer NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS avatar_data bytea;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS avatar_type text;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS chat_banned boolean NOT NULL DEFAULT false;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS is_test_profile boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS chat_messages (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    body text,
    image_data bytea,
    image_type text,
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CHECK(body IS NULL OR length(body)<=2000),
    CHECK((image_data IS NULL)=(image_type IS NULL))
);
CREATE INDEX IF NOT EXISTS chat_messages_created_idx ON chat_messages(created_at DESC,id DESC);
CREATE TABLE IF NOT EXISTS chat_reactions (
    message_id bigint NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    reaction text NOT NULL CHECK(reaction IN ('laugh','like','dislike')),
    PRIMARY KEY(message_id,account_id)
);
CREATE TABLE IF NOT EXISTS account_states (
    account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    layer text NOT NULL DEFAULT 'states' CHECK(layer='states'),
    state_id integer NOT NULL,
    PRIMARY KEY(account_id,state_id),
    FOREIGN KEY(layer,state_id) REFERENCES map_categories(layer,id) ON DELETE CASCADE
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
INSERT INTO schema_versions VALUES(2) ON CONFLICT DO NOTHING;
