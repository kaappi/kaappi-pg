CREATE UNIQUE INDEX idx_users_email ON mig_users(email);

ALTER TABLE mig_users ALTER COLUMN email SET NOT NULL;
-- DOWN
ALTER TABLE mig_users ALTER COLUMN email DROP NOT NULL;

DROP INDEX idx_users_email;
