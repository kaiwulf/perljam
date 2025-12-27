# OpenCy CMS Makefile
# Perl + Raku Content Management System

PERL        := perl
RAKU        := raku
SQLITE      := sqlite3
DB_FILE     := shared/cms.db
CPANM       := cpanm

# Ports
PERLJAM_PORT    := 8081
DANCER_PORT     := 5000
CRO_PORT        := 8080

# Directories
BACKEND_DIR     := backend
FRONTEND_DIR    := frontend
UPLOADS_DIR     := uploads
DOCROOT         := host-site/www

.PHONY: all setup install-deps init-db run run-perljam run-backend run-frontend \
        dev clean test help

# ═══════════════════════════════════════════════════════════════════════════════
# Default target
# ═══════════════════════════════════════════════════════════════════════════════

all: help

# ═══════════════════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════════════════

setup: install-deps init-dirs init-db
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║  OpenCy CMS setup complete!                                  ║"
	@echo "║                                                              ║"
	@echo "║  Run 'make dev' to start development servers                 ║"
	@echo "║  Or 'make run-perljam' to run perljam alone                  ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"

install-deps:
	@echo "Installing Perl dependencies..."
	$(CPANM) --installdeps . || $(CPANM) \
		IO::Async \
		Future::AsyncAwait \
		HTTP::Date \
		File::MimeInfo \
		JSON::PP \
		URI::Escape \
		Digest::SHA \
		DBI \
		DBD::SQLite \
		Text::Markdown \
		HTML::Escape \
		HTTP::Tiny
	@echo ""
	@echo "Installing Dancer2 (for backend)..."
	$(CPANM) Dancer2 Dancer2::Plugin::Database Template
	@echo ""
	@if command -v zef >/dev/null 2>&1; then \
		echo "Installing Raku dependencies..."; \
		zef install Cro::HTTP Cro::WebApp DB::SQLite; \
	else \
		echo "Raku/zef not found - skipping Cro installation"; \
	fi

init-dirs:
	@echo "Creating directories..."
	@mkdir -p $(DOCROOT)
	@mkdir -p $(UPLOADS_DIR)
	@mkdir -p $(BACKEND_DIR)/views/layouts
	@mkdir -p $(BACKEND_DIR)/views/posts
	@mkdir -p $(BACKEND_DIR)/views/pages
	@mkdir -p $(BACKEND_DIR)/public/css
	@mkdir -p $(BACKEND_DIR)/public/js
	@mkdir -p $(FRONTEND_DIR)/templates
	@mkdir -p $(FRONTEND_DIR)/static/css
	@mkdir -p shared
	@mkdir -p lib/PerlJam

init-db:
	@echo "Initializing database..."
	@rm -f $(DB_FILE)
	$(SQLITE) $(DB_FILE) < shared/schema.sql
	@echo "Database created: $(DB_FILE)"
	@echo "Default admin user: admin / admin123"

# ═══════════════════════════════════════════════════════════════════════════════
# Running
# ═══════════════════════════════════════════════════════════════════════════════

run: run-perljam

run-perljam:
	@echo "Starting perljam server on port $(PERLJAM_PORT)..."
	PERLJAM_PORT=$(PERLJAM_PORT) \
	PERLJAM_DOCROOT=$(DOCROOT) \
	DANCER_PORT=$(DANCER_PORT) \
	CRO_PORT=$(CRO_PORT) \
	$(PERL) -Ilib perljam-server.pl

run-backend:
	@echo "Starting Dancer2 backend on port $(DANCER_PORT)..."
	cd $(BACKEND_DIR) && \
	DANCER_PORT=$(DANCER_PORT) \
	$(PERL) -I../lib -Ilib bin/app.pl

run-frontend:
	@echo "Starting Cro frontend on port $(CRO_PORT)..."
	cd $(FRONTEND_DIR) && \
	$(RAKU) -I../lib -Ilib bin/frontend-server.raku

# Development mode: run all servers
dev:
	@echo "Starting development environment..."
	@echo "  perljam:  http://localhost:$(PERLJAM_PORT)"
	@echo "  backend:  http://localhost:$(DANCER_PORT)"
	@echo ""
	@echo "Press Ctrl+C to stop all servers"
	@$(MAKE) -j2 run-perljam run-backend

# Run perljam with auto-reload (requires App::Prove::Watch or similar)
dev-perljam:
	@which fswatch >/dev/null 2>&1 || (echo "Install fswatch for auto-reload" && exit 1)
	@echo "Starting perljam with auto-reload..."
	@while true; do \
		$(MAKE) run-perljam & PID=$$!; \
		fswatch -1 -r lib/ perljam-server.pl; \
		kill $$PID 2>/dev/null; \
		echo "Restarting..."; \
	done

# ═══════════════════════════════════════════════════════════════════════════════
# Testing
# ═══════════════════════════════════════════════════════════════════════════════

test:
	@echo "Running tests..."
	prove -Ilib -r t/

test-server:
	@echo "Testing perljam server..."
	@$(MAKE) run-perljam &
	@sleep 2
	@curl -s http://localhost:$(PERLJAM_PORT)/health | jq .
	@curl -s -o /dev/null -w "%{http_code}" http://localhost:$(PERLJAM_PORT)/
	@pkill -f perljam-server

# ═══════════════════════════════════════════════════════════════════════════════
# Utilities
# ═══════════════════════════════════════════════════════════════════════════════

clean:
	@echo "Cleaning..."
	@rm -f $(DB_FILE)
	@rm -rf $(UPLOADS_DIR)/*
	@find . -name "*.bak" -delete
	@find . -name "*~" -delete

clean-all: clean
	@rm -rf local/

# Database commands
db-shell:
	$(SQLITE) $(DB_FILE)

db-dump:
	$(SQLITE) $(DB_FILE) .dump > shared/backup.sql

db-restore:
	$(SQLITE) $(DB_FILE) < shared/backup.sql

# Create a sample index.html for testing
sample-site:
	@echo "Creating sample site..."
	@mkdir -p $(DOCROOT)
	@echo '<!DOCTYPE html>' > $(DOCROOT)/index.html
	@echo '<html><head><title>OpenCy CMS</title></head>' >> $(DOCROOT)/index.html
	@echo '<body><h1>Welcome to OpenCy</h1>' >> $(DOCROOT)/index.html
	@echo '<p>perljam server is running!</p>' >> $(DOCROOT)/index.html
	@echo '<p><a href="/admin">Admin Panel</a></p>' >> $(DOCROOT)/index.html
	@echo '</body></html>' >> $(DOCROOT)/index.html
	@echo "Created $(DOCROOT)/index.html"

# ═══════════════════════════════════════════════════════════════════════════════
# Help
# ═══════════════════════════════════════════════════════════════════════════════

help:
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║  OpenCy CMS - Makefile Commands                              ║"
	@echo "╠══════════════════════════════════════════════════════════════╣"
	@echo "║                                                              ║"
	@echo "║  Setup:                                                      ║"
	@echo "║    make setup        - Full setup (deps + dirs + db)         ║"
	@echo "║    make install-deps - Install Perl/Raku dependencies        ║"
	@echo "║    make init-db      - Initialize/reset the database         ║"
	@echo "║    make sample-site  - Create sample index.html              ║"
	@echo "║                                                              ║"
	@echo "║  Running:                                                    ║"
	@echo "║    make run          - Run perljam server                    ║"
	@echo "║    make run-perljam  - Run perljam server                    ║"
	@echo "║    make run-backend  - Run Dancer2 backend                   ║"
	@echo "║    make run-frontend - Run Cro frontend                      ║"
	@echo "║    make dev          - Run all servers for development       ║"
	@echo "║                                                              ║"
	@echo "║  Database:                                                   ║"
	@echo "║    make db-shell     - Open SQLite shell                     ║"
	@echo "║    make db-dump      - Dump database to backup.sql           ║"
	@echo "║    make db-restore   - Restore from backup.sql               ║"
	@echo "║                                                              ║"
	@echo "║  Utilities:                                                  ║"
	@echo "║    make test         - Run test suite                        ║"
	@echo "║    make clean        - Remove generated files                ║"
	@echo "║                                                              ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"
