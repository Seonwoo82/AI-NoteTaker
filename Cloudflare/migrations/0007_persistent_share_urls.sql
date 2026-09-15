ALTER TABLE web_shares ADD COLUMN public_token TEXT;

CREATE UNIQUE INDEX idx_web_shares_public_token ON web_shares (public_token);
