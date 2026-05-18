CREATE ROLE root LOGIN;
CREATE DATABASE root OWNER root;

-- CREATE TABLE goose_db_version (
--   id SERIAL PRIMARY KEY,
--   version_id BIGINT NOT NULL,
--   is_applied BOOLEAN NOT NULL,
--   tstamp TIMESTAMP DEFAULT now()
-- );
