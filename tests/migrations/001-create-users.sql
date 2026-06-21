CREATE TABLE mig_users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT
);
-- DOWN
DROP TABLE mig_users;
