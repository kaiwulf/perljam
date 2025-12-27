# OpenCy CMS - Minimal Edition Makefile
# No CPAN dependencies - just core Perl

PERL     := perl
SQLITE   := sqlite3
DB_FILE  := cms.db

.PHONY: all run setup init-db clean test help

all: help

#═══════════════════════════════════════════════════════════════════════════════
# Setup (no cpanm needed!)
#═══════════════════════════════════════════════════════════════════════════════

setup: check-deps init-dirs init-db sample-site
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║  Setup complete! Run 'make run' to start the server.         ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"

check-deps:
	@echo "Checking dependencies..."
	@$(PERL) -v >/dev/null 2>&1 || (echo "ERROR: Perl not found" && exit 1)
	@$(PERL) -e 'use 5.014' 2>/dev/null || (echo "ERROR: Perl 5.14+ required" && exit 1)
	@$(SQLITE) -version >/dev/null 2>&1 || (echo "ERROR: sqlite3 not found" && exit 1)
	@echo "  ✓ Perl $$($(PERL) -e 'print $$^V')"
	@echo "  ✓ SQLite $$($(SQLITE) -version | head -1)"

init-dirs:
	@mkdir -p public uploads views/admin views/blog views/layouts

init-db:
	@echo "Initializing database..."
	@rm -f $(DB_FILE)
	@$(SQLITE) $(DB_FILE) < schema.sql
	@echo "  ✓ Database created: $(DB_FILE)"
	@echo "  ✓ Admin user: admin / admin123"

#═══════════════════════════════════════════════════════════════════════════════
# Running
#═══════════════════════════════════════════════════════════════════════════════

run:
	@$(PERL) perljam-server.pl

# Run with auto-restart on file changes (if entr is installed)
dev:
	@which entr >/dev/null 2>&1 && \
		find lib -name '*.pm' | entr -r $(PERL) perljam-server.pl || \
		$(MAKE) run

#═══════════════════════════════════════════════════════════════════════════════
# Utilities
#═══════════════════════════════════════════════════════════════════════════════

sample-site:
	@echo "Creating sample templates..."
	@echo '<!DOCTYPE html>' > views/layouts/base.tt
	@echo '<html><head><title><%$$title%> - OpenCy</title>' >> views/layouts/base.tt
	@echo '<style>body{font-family:system-ui;max-width:800px;margin:40px auto;padding:20px}</style>' >> views/layouts/base.tt
	@echo '</head><body><%=$$content%></body></html>' >> views/layouts/base.tt
	@echo '<%layout "base.tt"%><h1>Welcome to OpenCy</h1><p>Your CMS is running!</p>' > views/home.tt
	@echo '<%layout "base.tt"%><h1>Login</h1><%if $$error%><p style="color:red"><%$$error%></p><%end%>' > views/admin/login.tt
	@echo '<form method="POST"><input name="username" placeholder="Username"><input type="password" name="password" placeholder="Password"><button>Login</button></form>' >> views/admin/login.tt
	@echo "index.html" > public/index.html
	@echo "  ✓ Sample templates created"

db-shell:
	@$(SQLITE) $(DB_FILE)

clean:
	@rm -f $(DB_FILE)
	@rm -rf uploads/*

test:
	@echo "Testing modules..."
	@$(PERL) -Ilib -e 'use PerlJam::Util; print "  ✓ PerlJam::Util\n"'
	@$(PERL) -Ilib -e 'use PerlJam::Server; print "  ✓ PerlJam::Server\n"'
	@$(PERL) -Ilib -e 'use PerlJam::Template; print "  ✓ PerlJam::Template\n"'
	@$(PERL) -Ilib -e 'use PerlJam::Markdown; print "  ✓ PerlJam::Markdown\n"'
	@$(PERL) -Ilib -e 'use PerlJam::DB; print "  ✓ PerlJam::DB\n"'
	@echo "All modules OK!"

#═══════════════════════════════════════════════════════════════════════════════
# Help
#═══════════════════════════════════════════════════════════════════════════════

help:
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║  OpenCy CMS - Minimal Edition                                ║"
	@echo "║  No CPAN dependencies required!                              ║"
	@echo "╠══════════════════════════════════════════════════════════════╣"
	@echo "║                                                              ║"
	@echo "║  make setup     - Initialize everything                      ║"
	@echo "║  make run       - Start the server                           ║"
	@echo "║  make dev       - Run with auto-reload (needs entr)          ║"
	@echo "║  make test      - Test all modules load                      ║"
	@echo "║  make db-shell  - Open SQLite shell                          ║"
	@echo "║  make clean     - Remove database and uploads                ║"
	@echo "║                                                              ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"
