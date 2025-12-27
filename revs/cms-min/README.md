# OpenCy CMS - Minimal Edition

A content management system built with only **core Perl modules**.
No CPAN dependencies required.

## Philosophy

Inspired by the FSF, early hacker culture, and Douglas Engelbart's vision
of technology augmenting human capabilities rather than replacing them.
We believe in understanding our tools by building them ourselves.

## Dependency Comparison

### Full Version (original)
```
IO::Async              - Async event loop
Future::AsyncAwait     - Async/await syntax  
HTTP::Date             - Date formatting
File::MimeInfo         - MIME detection
URI::Escape            - URL encoding
Dancer2                - Web framework
Template               - Template Toolkit
Text::Markdown         - Markdown parser
HTML::Escape           - HTML escaping
DBI + DBD::SQLite      - Database
HTTP::Tiny             - HTTP client
```

### Minimal Version (this)
```
(none)                 - All functionality built from scratch
```

**External tools:** Only `sqlite3` CLI (usually pre-installed)

## What We Built

| Module | Replaces | Lines |
|--------|----------|-------|
| `PerlJam::Util` | URI::Escape, HTML::Escape, HTTP::Date, File::MimeInfo | ~250 |
| `PerlJam::Server` | IO::Async + HTTP handling | ~500 |
| `PerlJam::Template` | Template Toolkit | ~200 |
| `PerlJam::Markdown` | Text::Markdown | ~180 |
| `PerlJam::DB` | DBI (falls back to sqlite3 CLI) | ~200 |

**Total:** ~1,330 lines replacing ~50,000+ lines of CPAN code

## Core Modules Used

These are included with Perl 5.14+:

- `IO::Socket::INET` - TCP sockets
- `IO::Select` - Non-blocking multiplexing
- `JSON::PP` - JSON parsing (core since 5.14)
- `Digest::SHA` - Cryptographic hashing (core since 5.9.3)
- `MIME::Base64` - Base64 encoding
- `Socket` - Low-level socket constants
- `POSIX` - System interface
- `File::Spec`, `Cwd` - Path handling
- `Time::Local` - Time parsing

## Installation

```bash
# No cpanm needed!
git clone <repo>
cd cms-minimal

# Initialize database (requires sqlite3)
sqlite3 cms.db < schema.sql

# Run
perl perljam-server.pl
```

## Features

Despite being minimal, we support:

- **HTTP/1.1** with keep-alive
- **Non-blocking I/O** via IO::Select
- **URL routing** with parameters (`:id`, `:slug*`)
- **Static file serving** with MIME types
- **Form parsing** (urlencoded + multipart)
- **JSON API** endpoints
- **File uploads**
- **Cookie sessions**
- **Markdown** (headings, bold, italic, links, images, code, lists, quotes)
- **Templates** (variables, if/else, loops, includes)
- **SQLite database** abstraction

## Limitations

The minimal versions have some limitations compared to full libraries:

**Markdown:**
- No tables
- No footnotes
- No reference-style links
- Basic nested list support

**Templates:**
- No filters/plugins
- No complex expressions
- No caching (yet)

**Server:**
- Single-threaded (fine for low-medium traffic)
- No chunked transfer encoding
- No WebSocket support

**Database:**
- SQLite only (CLI fallback is slower)

## Upgrading

If you need more features, you can selectively add CPAN modules:

```perl
# In perljam-server.pl, the DB module auto-detects DBI:
# Just install it and restart:
cpanm DBI DBD::SQLite

# For async with thousands of connections:
cpanm IO::Async
# Then swap PerlJam::Server for IO::Async-based version
```

## Project Structure

```
cms-minimal/
├── perljam-server.pl      # Main application
├── lib/PerlJam/
│   ├── Server.pm          # HTTP server (replaces IO::Async)
│   ├── Util.pm            # URI, HTML, Date, MIME utilities
│   ├── Template.pm        # Template engine
│   ├── Markdown.pm        # Markdown parser
│   └── DB.pm              # SQLite wrapper
├── views/                 # Templates
├── public/                # Static files
├── uploads/               # User uploads
├── schema.sql             # Database schema
└── cpanfile               # (nearly empty!)
```

## License

Free as in freedom. Use, study, modify, share.

---

*"The best way to understand something is to build it yourself."*
