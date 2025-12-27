-- OpenCy CMS Database Schema
-- SQLite compatible

-- Users table
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username VARCHAR(64) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(32) DEFAULT 'author',  -- admin, editor, author
    display_name VARCHAR(128),
    bio TEXT,
    avatar_url VARCHAR(512),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_login DATETIME
);

-- Blog posts
CREATE TABLE IF NOT EXISTS posts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title VARCHAR(255) NOT NULL,
    slug VARCHAR(255) UNIQUE NOT NULL,
    excerpt TEXT,
    content_markdown TEXT,
    content_html TEXT,
    author_id INTEGER NOT NULL REFERENCES users(id),
    published BOOLEAN DEFAULT 0,
    published_at DATETIME,
    featured BOOLEAN DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_posts_slug ON posts(slug);
CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author_id);
CREATE INDEX IF NOT EXISTS idx_posts_published ON posts(published, published_at DESC);

-- Static pages
CREATE TABLE IF NOT EXISTS pages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title VARCHAR(255) NOT NULL,
    slug VARCHAR(255) UNIQUE NOT NULL,
    content_markdown TEXT,
    content_html TEXT,
    template VARCHAR(64) DEFAULT 'default',
    parent_id INTEGER REFERENCES pages(id),
    menu_order INTEGER DEFAULT 0,
    published BOOLEAN DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_pages_slug ON pages(slug);
CREATE INDEX IF NOT EXISTS idx_pages_parent ON pages(parent_id);

-- Tags for posts
CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(64) NOT NULL,
    slug VARCHAR(64) UNIQUE NOT NULL,
    description TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Post-Tag relationship (many-to-many)
CREATE TABLE IF NOT EXISTS post_tags (
    post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (post_id, tag_id)
);

-- Categories (hierarchical)
CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(64) NOT NULL,
    slug VARCHAR(64) UNIQUE NOT NULL,
    description TEXT,
    parent_id INTEGER REFERENCES categories(id),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Post-Category relationship
CREATE TABLE IF NOT EXISTS post_categories (
    post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    PRIMARY KEY (post_id, category_id)
);

-- Media/uploads
CREATE TABLE IF NOT EXISTS media (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename VARCHAR(255) NOT NULL,
    original_name VARCHAR(255),
    mime_type VARCHAR(128),
    size INTEGER,
    path VARCHAR(512) NOT NULL,
    alt_text VARCHAR(255),
    caption TEXT,
    uploader_id INTEGER REFERENCES users(id),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Comments (optional)
CREATE TABLE IF NOT EXISTS comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    parent_id INTEGER REFERENCES comments(id),
    author_name VARCHAR(128),
    author_email VARCHAR(255),
    author_url VARCHAR(512),
    content TEXT NOT NULL,
    approved BOOLEAN DEFAULT 0,
    ip_address VARCHAR(45),
    user_agent TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_comments_post ON comments(post_id);
CREATE INDEX IF NOT EXISTS idx_comments_approved ON comments(approved, created_at DESC);

-- Site settings (key-value store)
CREATE TABLE IF NOT EXISTS settings (
    key VARCHAR(128) PRIMARY KEY,
    value TEXT,
    type VARCHAR(32) DEFAULT 'string',  -- string, json, boolean, integer
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Session storage (if not using file sessions)
CREATE TABLE IF NOT EXISTS sessions (
    id VARCHAR(128) PRIMARY KEY,
    data TEXT,
    expires_at DATETIME
);

-- Insert default admin user (password: admin123)
-- SHA256 hash of 'admin123'
INSERT OR IGNORE INTO users (username, email, password_hash, role, display_name)
VALUES (
    'admin',
    'admin@localhost',
    '240be518fabd2724ddb6f04eeb9d5b8b9f7b6c15db0b4f1e08e0d4a29fd1b6d8',
    'admin',
    'Administrator'
);

-- Insert default settings
INSERT OR IGNORE INTO settings (key, value, type) VALUES
    ('site_title', 'OpenCy', 'string'),
    ('site_description', 'Free and Open Source CMS', 'string'),
    ('posts_per_page', '10', 'integer'),
    ('allow_comments', 'true', 'boolean'),
    ('require_comment_approval', 'true', 'boolean');
