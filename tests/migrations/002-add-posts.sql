CREATE TABLE mig_posts (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES mig_users(id),
  title TEXT NOT NULL,
  body TEXT,
  created_at TIMESTAMP DEFAULT now()
);

CREATE INDEX idx_posts_user ON mig_posts(user_id);
-- DOWN
DROP TABLE mig_posts;
