#!/usr/bin/env perl
#
# perljam-server.pl - Async HTTP server for OpenCy CMS
# Integrates with Dancer2 backend and Cro frontend
#
use strict;
use warnings;
use v5.24;

use IO::Async::Loop;
use IO::Async::Listener;
use IO::Async::Stream;
use HTTP::Date qw(time2str);
use File::MimeInfo;
use File::Spec;
use Cwd 'abs_path';
use JSON::PP;
use URI::Escape qw(uri_unescape);
use MIME::Base64;
use Digest::SHA qw(sha256_hex);

# Load CMS integration module
use lib 'lib';
use PerlJam::Router;
use PerlJam::Request;
use PerlJam::Response;

our $VERSION = '0.1.0';

# Configuration (can be overridden via environment)
our %config = (
    document_root  => $ENV{PERLJAM_DOCROOT}  // 'host-site/www/',
    port           => $ENV{PERLJAM_PORT}     // 8081,
    host           => $ENV{PERLJAM_HOST}     // '0.0.0.0',
    max_body_size  => $ENV{PERLJAM_MAX_BODY} // 10 * 1024 * 1024,  # 10MB
    upload_dir     => $ENV{PERLJAM_UPLOADS}  // 'uploads/',
    backend_port   => $ENV{DANCER_PORT}      // 5000,
    frontend_port  => $ENV{CRO_PORT}         // 8080,
    session_secret => $ENV{SESSION_SECRET}   // 'change-me-in-production',
);

our @index_files = ('index.html', 'index.htm', 'index.raku', 'index.pl');
our $loop = IO::Async::Loop->new;
our $abs_doc_root;
our $json = JSON::PP->new->utf8->pretty;
our $router = PerlJam::Router->new;

# Status messages
our %status_messages = (
    200 => 'OK',
    201 => 'Created',
    204 => 'No Content',
    301 => 'Moved Permanently',
    302 => 'Found',
    304 => 'Not Modified',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    413 => 'Payload Too Large',
    415 => 'Unsupported Media Type',
    500 => 'Internal Server Error',
);

#═══════════════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════════════

sub debug_print {
    my ($message) = @_;
    my $timestamp = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime);
    say STDERR "[$timestamp] $message";
}

sub get_mime_type {
    my ($file) = @_;
    my $mime_type = mimetype($file) || 'application/octet-stream';
    $mime_type .= '; charset=utf-8' if $mime_type =~ m{^text/} && $mime_type !~ /charset/;
    return $mime_type;
}

#═══════════════════════════════════════════════════════════════════════════════
# Request Body Parsing
#═══════════════════════════════════════════════════════════════════════════════

sub parse_urlencoded {
    my ($body) = @_;
    my %params;
    
    for my $pair (split /&/, $body) {
        my ($key, $value) = split /=/, $pair, 2;
        next unless defined $key;
        
        $key   = uri_unescape($key   // '');
        $value = uri_unescape($value // '');
        
        # Handle array parameters (key[] or repeated keys)
        $key =~ s/\[\]$//;
        
        if (exists $params{$key}) {
            if (ref $params{$key} eq 'ARRAY') {
                push @{$params{$key}}, $value;
            } else {
                $params{$key} = [$params{$key}, $value];
            }
        } else {
            $params{$key} = $value;
        }
    }
    
    return \%params;
}

sub parse_multipart {
    my ($body, $boundary) = @_;
    my %params;
    my @files;
    
    # Split on boundary
    my @parts = split /--\Q$boundary\E/, $body;
    shift @parts;  # Remove preamble
    
    for my $part (@parts) {
        next if $part =~ /^--/;  # Skip epilogue
        next unless $part =~ /\S/;
        
        # Split headers from content
        my ($headers, $content) = split /\r?\n\r?\n/, $part, 2;
        next unless defined $content;
        
        # Remove trailing CRLF
        $content =~ s/\r?\n$//;
        
        # Parse Content-Disposition
        my ($name, $filename);
        if ($headers =~ /Content-Disposition:.*?name="([^"]+)"/i) {
            $name = $1;
        }
        if ($headers =~ /Content-Disposition:.*?filename="([^"]+)"/i) {
            $filename = $1;
        }
        
        # Get content type if present
        my $content_type = 'text/plain';
        if ($headers =~ /Content-Type:\s*(\S+)/i) {
            $content_type = $1;
        }
        
        if (defined $filename && $filename ne '') {
            # File upload
            push @files, {
                name         => $name,
                filename     => $filename,
                content_type => $content_type,
                content      => $content,
                size         => length($content),
            };
        } else {
            # Regular field
            $params{$name} = $content if defined $name;
        }
    }
    
    return (\%params, \@files);
}

sub parse_json_body {
    my ($body) = @_;
    
    return {} unless defined $body && $body =~ /\S/;
    
    my $data;
    eval {
        $data = $json->decode($body);
    };
    
    if ($@) {
        debug_print("JSON parse error: $@");
        return undef;
    }
    
    return $data;
}

sub parse_request_body {
    my ($request) = @_;
    
    my $content_type = $request->{headers}{'content-type'} // '';
    my $body = $request->{body} // '';
    
    if ($content_type =~ m{^application/x-www-form-urlencoded}i) {
        $request->{params} = parse_urlencoded($body);
        $request->{body_type} = 'form';
    }
    elsif ($content_type =~ m{^multipart/form-data.*boundary=(.+)}i) {
        my $boundary = $1;
        $boundary =~ s/^["']|["']$//g;  # Remove quotes if present
        my ($params, $files) = parse_multipart($body, $boundary);
        $request->{params} = $params;
        $request->{files}  = $files;
        $request->{body_type} = 'multipart';
    }
    elsif ($content_type =~ m{^application/json}i) {
        my $data = parse_json_body($body);
        if (defined $data) {
            $request->{json} = $data;
            $request->{body_type} = 'json';
        } else {
            return 0;  # Parse failed
        }
    }
    elsif ($content_type =~ m{^text/}) {
        $request->{text} = $body;
        $request->{body_type} = 'text';
    }
    else {
        $request->{raw_body} = $body;
        $request->{body_type} = 'raw';
    }
    
    return 1;
}

#═══════════════════════════════════════════════════════════════════════════════
# Cookie & Session Handling
#═══════════════════════════════════════════════════════════════════════════════

sub parse_cookies {
    my ($cookie_header) = @_;
    my %cookies;
    
    return \%cookies unless defined $cookie_header;
    
    for my $cookie (split /;\s*/, $cookie_header) {
        my ($name, $value) = split /=/, $cookie, 2;
        next unless defined $name && defined $value;
        $name  =~ s/^\s+|\s+$//g;
        $value =~ s/^\s+|\s+$//g;
        $cookies{$name} = $value;
    }
    
    return \%cookies;
}

sub build_set_cookie {
    my ($name, $value, %options) = @_;
    
    my $cookie = "$name=$value";
    $cookie .= "; Path=" . ($options{path} // '/');
    $cookie .= "; HttpOnly" if $options{httponly} // 1;
    $cookie .= "; Secure" if $options{secure};
    $cookie .= "; SameSite=" . ($options{samesite} // 'Lax');
    
    if (my $max_age = $options{max_age}) {
        $cookie .= "; Max-Age=$max_age";
    }
    
    return $cookie;
}

#═══════════════════════════════════════════════════════════════════════════════
# HTTP Response Building
#═══════════════════════════════════════════════════════════════════════════════

sub build_headers {
    my ($status_code, $content_type, $content_length, $extra_headers) = @_;
    $extra_headers //= {};
    
    my $status_text = $status_messages{$status_code} // 'Unknown';
    
    my @headers = (
        "HTTP/1.1 $status_code $status_text",
        "Server: perljam/$VERSION",
        "Date: " . time2str(time()),
        "X-Frame-Options: DENY",
        "X-Content-Type-Options: nosniff",
        "X-XSS-Protection: 1; mode=block",
        "Content-Type: $content_type",
        "Content-Length: $content_length",
        "Connection: keep-alive",
    );
    
    for my $key (keys %$extra_headers) {
        my $value = $extra_headers->{$key};
        if (ref $value eq 'ARRAY') {
            push @headers, "$key: $_" for @$value;
        } else {
            push @headers, "$key: $value";
        }
    }
    
    return join("\r\n", @headers) . "\r\n\r\n";
}

sub send_response {
    my ($stream, $status, $content_type, $body, $extra_headers) = @_;
    $body //= '';
    
    my $response = build_headers($status, $content_type, length($body), $extra_headers);
    $stream->write($response . $body);
    
    debug_print("Response: $status $status_messages{$status}");
}

sub send_json {
    my ($stream, $status, $data, $extra_headers) = @_;
    my $body = $json->encode($data);
    send_response($stream, $status, 'application/json', $body, $extra_headers);
}

sub send_redirect {
    my ($stream, $location, $status) = @_;
    $status //= 302;
    
    my $body = qq{<html><body>Redirecting to <a href="$location">$location</a></body></html>};
    send_response($stream, $status, 'text/html', $body, { Location => $location });
}

sub send_error {
    my ($stream, $status_code, $message) = @_;
    $message //= $status_messages{$status_code} // 'Error';
    
    my $body = <<"HTML";
<!DOCTYPE html>
<html>
<head>
    <title>$status_code $status_messages{$status_code}</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; }
        h1 { color: #c00; }
        .footer { margin-top: 30px; color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>$status_code $status_messages{$status_code}</h1>
    <p>$message</p>
    <div class="footer">perljam/$VERSION</div>
</body>
</html>
HTML

    send_response($stream, $status_code, 'text/html; charset=utf-8', $body);
}

#═══════════════════════════════════════════════════════════════════════════════
# Static File Serving
#═══════════════════════════════════════════════════════════════════════════════

sub is_path_safe {
    my ($resolved_path) = @_;
    return 0 unless defined $resolved_path;
    return 0 unless $resolved_path =~ /^\Q$abs_doc_root\E/;
    return 1;
}

sub resolve_path {
    my ($request_path) = @_;
    
    $request_path =~ s/^\/+//;
    $request_path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $request_path =~ s/\?.*//;
    $request_path =~ s/#.*//;
    
    my $full_path = File::Spec->catfile($config{document_root}, $request_path);
    my $resolved = abs_path($full_path);
    
    if (defined $resolved && -d $resolved) {
        for my $index (@index_files) {
            my $index_path = File::Spec->catfile($resolved, $index);
            return $index_path if -f $index_path;
        }
        return undef;
    }
    
    return $resolved;
}

sub serve_static {
    my ($stream, $request) = @_;
    
    my $path = $request->{path};
    my $resolved_path = resolve_path($path);
    
    unless (is_path_safe($resolved_path)) {
        debug_print("Security: blocked path traversal: $path");
        send_error($stream, 403, "Access denied");
        return;
    }
    
    unless (defined $resolved_path && -f $resolved_path && -r $resolved_path) {
        send_error($stream, 404, "The requested resource was not found.");
        return;
    }
    
    my @stat = stat($resolved_path);
    my $size = $stat[7];
    my $mtime = $stat[9];
    my $content_type = get_mime_type($resolved_path);
    
    # HEAD request
    if ($request->{method} eq 'HEAD') {
        my $response = build_headers(200, $content_type, $size, {
            'Last-Modified' => time2str($mtime),
            'Cache-Control' => 'public, max-age=3600',
        });
        $stream->write($response);
        debug_print("HEAD $path -> 200 ($size bytes)");
        return;
    }
    
    # Read file
    my $content;
    unless (open my $fh, '<:raw', $resolved_path) {
        debug_print("Failed to open $resolved_path: $!");
        send_error($stream, 500, "Could not read file");
        return;
    } else {
        local $/;
        $content = <$fh>;
        close $fh;
    }
    
    send_response($stream, 200, $content_type, $content, {
        'Last-Modified' => time2str($mtime),
        'Cache-Control' => 'public, max-age=3600',
    });
    
    debug_print("GET $path -> 200 ($size bytes)");
}

#═══════════════════════════════════════════════════════════════════════════════
# File Upload Handling
#═══════════════════════════════════════════════════════════════════════════════

sub save_uploaded_file {
    my ($file) = @_;
    
    # Generate safe filename
    my $ext = '';
    if ($file->{filename} =~ /\.(\w+)$/) {
        $ext = lc($1);
    }
    
    my $hash = substr(sha256_hex($file->{content} . time()), 0, 16);
    my $safe_name = "${hash}.${ext}";
    
    my $upload_path = File::Spec->catfile($config{upload_dir}, $safe_name);
    
    # Ensure upload directory exists
    unless (-d $config{upload_dir}) {
        mkdir $config{upload_dir}, 0755 or do {
            debug_print("Failed to create upload dir: $!");
            return undef;
        };
    }
    
    # Write file
    if (open my $fh, '>:raw', $upload_path) {
        print $fh $file->{content};
        close $fh;
        
        return {
            path          => $upload_path,
            url           => "/uploads/$safe_name",
            original_name => $file->{filename},
            size          => $file->{size},
            content_type  => $file->{content_type},
        };
    }
    
    debug_print("Failed to save upload: $!");
    return undef;
}

#═══════════════════════════════════════════════════════════════════════════════
# Request Parsing & Handling
#═══════════════════════════════════════════════════════════════════════════════

sub parse_request_headers {
    my ($raw_headers) = @_;
    
    my @lines = split /\r?\n/, $raw_headers;
    my $request_line = shift @lines;
    
    return undef unless $request_line =~ /^([A-Z]+)\s+(\S+)\s+HTTP\/1\.[01]$/;
    
    my ($method, $uri) = ($1, $2);
    
    # Split path and query string
    my ($path, $query_string) = split /\?/, $uri, 2;
    
    # Parse headers
    my %headers;
    for my $line (@lines) {
        last if $line eq '';
        if ($line =~ /^([^:]+):\s*(.*)$/) {
            $headers{lc($1)} = $2;
        }
    }
    
    return {
        method       => $method,
        path         => $path,
        uri          => $uri,
        query_string => $query_string // '',
        query        => parse_urlencoded($query_string // ''),
        headers      => \%headers,
        cookies      => parse_cookies($headers{cookie}),
    };
}

sub handle_request {
    my ($stream, $request) = @_;
    
    # Parse body for POST/PUT/PATCH
    if ($request->{method} =~ /^(POST|PUT|PATCH)$/) {
        unless (parse_request_body($request)) {
            send_error($stream, 400, "Failed to parse request body");
            return;
        }
    }
    
    # Create request/response objects for router
    my $req = PerlJam::Request->new($request);
    my $res = PerlJam::Response->new($stream);
    
    # Try router first
    if ($router->dispatch($req, $res)) {
        return;  # Route handled the request
    }
    
    # Fall back to static file serving for GET/HEAD
    if ($request->{method} =~ /^(GET|HEAD)$/) {
        serve_static($stream, $request);
    } else {
        send_error($stream, 405, "Method not allowed");
    }
}

#═══════════════════════════════════════════════════════════════════════════════
# Connection Handler
#═══════════════════════════════════════════════════════════════════════════════

sub handle_connection {
    my ($self, $stream) = @_;
    
    my $peer = $stream->read_handle->peerhost // 'unknown';
    debug_print("Connection from $peer");
    
    my $body_remaining = 0;
    my $current_request;
    
    $stream->configure(
        on_read => sub {
            my ($self, $buffref, $eof) = @_;
            
            # Reading body?
            if ($body_remaining > 0) {
                if (length($$buffref) >= $body_remaining) {
                    $current_request->{body} .= substr($$buffref, 0, $body_remaining, '');
                    $body_remaining = 0;
                    
                    # Process complete request
                    handle_request($stream, $current_request);
                    $current_request = undef;
                    return 1;
                } else {
                    $current_request->{body} .= $$buffref;
                    $body_remaining -= length($$buffref);
                    $$buffref = '';
                    return 0;
                }
            }
            
            # Look for complete headers
            if ($$buffref =~ s/^(.*?\r?\n\r?\n)//s) {
                my $headers = $1;
                
                my $request = parse_request_headers($headers);
                
                unless ($request) {
                    send_error($stream, 400, "Malformed HTTP request");
                    return 1;
                }
                
                debug_print("$request->{method} $request->{path}");
                
                # Check for request body
                my $content_length = $request->{headers}{'content-length'} // 0;
                
                if ($content_length > $config{max_body_size}) {
                    send_error($stream, 413, "Request body too large");
                    return 1;
                }
                
                if ($content_length > 0) {
                    $request->{body} = '';
                    
                    # Some body may already be in buffer
                    if (length($$buffref) >= $content_length) {
                        $request->{body} = substr($$buffref, 0, $content_length, '');
                        handle_request($stream, $request);
                    } else {
                        $request->{body} = $$buffref;
                        $$buffref = '';
                        $body_remaining = $content_length - length($request->{body});
                        $current_request = $request;
                    }
                } else {
                    handle_request($stream, $request);
                }
                
                return 1;
            }
            
            if ($eof) {
                debug_print("Client disconnected");
            }
            
            return 0;
        },
        
        on_read_error => sub {
            my ($self, $errno) = @_;
            debug_print("Read error: $errno");
        },
        
        on_write_error => sub {
            my ($self, $errno) = @_;
            debug_print("Write error: $errno");
        },
    );
    
    $loop->add($stream);
}

#═══════════════════════════════════════════════════════════════════════════════
# CMS Route Registration
#═══════════════════════════════════════════════════════════════════════════════

sub setup_cms_routes {
    
    # API: Markdown preview
    $router->post('/api/preview' => sub {
        my ($req, $res) = @_;
        
        my $markdown = $req->param('markdown') // $req->json->{markdown} // '';
        
        # Use Text::Markdown if available, else simple conversion
        my $html;
        eval {
            require Text::Markdown;
            $html = Text::Markdown::markdown($markdown);
        };
        if ($@) {
            # Fallback: basic escaping
            $html = $markdown;
            $html =~ s/&/&amp;/g;
            $html =~ s/</&lt;/g;
            $html =~ s/>/&gt;/g;
            $html =~ s/\n/<br>/g;
        }
        
        $res->json({ html => $html });
    });
    
    # API: File upload
    $router->post('/api/upload' => sub {
        my ($req, $res) = @_;
        
        my @results;
        for my $file (@{$req->files}) {
            my $saved = save_uploaded_file($file);
            if ($saved) {
                push @results, $saved;
            }
        }
        
        if (@results) {
            $res->json({ success => 1, files => \@results });
        } else {
            $res->status(400)->json({ success => 0, error => 'No files uploaded' });
        }
    });
    
    # Proxy to Dancer2 backend for /admin routes
    $router->any('/admin/:path*' => sub {
        my ($req, $res) = @_;
        # In production, this would proxy to Dancer2
        # For now, redirect to backend port
        my $backend_url = "http://localhost:$config{backend_port}" . $req->path;
        $res->redirect($backend_url);
    });
    
    # Health check endpoint
    $router->get('/health' => sub {
        my ($req, $res) = @_;
        $res->json({
            status  => 'ok',
            server  => "perljam/$VERSION",
            uptime  => time() - $^T,
        });
    });
    
    debug_print("CMS routes registered");
}

#═══════════════════════════════════════════════════════════════════════════════
# Main Entry Point
#═══════════════════════════════════════════════════════════════════════════════

sub main {
    # Resolve document root
    $abs_doc_root = abs_path($config{document_root}) // $config{document_root};
    
    # Ensure document root exists
    unless (-d $abs_doc_root) {
        die "Document root does not exist: $abs_doc_root\n";
    }
    
    # Setup CMS routes
    setup_cms_routes();
    
    # Create listener
    my $listener = IO::Async::Listener->new(
        on_stream => \&handle_connection,
    );
    
    $loop->add($listener);
    
    # Start listening
    eval {
        $listener->listen(
            addr => {
                family   => 'inet',
                socktype => 'stream',
                ip       => $config{host},
                port     => $config{port},
            },
        )->get;
    };
    
    if ($@) {
        die "Failed to bind to $config{host}:$config{port}: $@\n";
    }
    
    say "╔══════════════════════════════════════════════════════════════╗";
    say "║  perljam server v$VERSION                                      ║";
    say "╠══════════════════════════════════════════════════════════════╣";
    say "║  Listening: http://$config{host}:$config{port}                          ║";
    say "║  Document root: $abs_doc_root";
    say "║  Backend (Dancer2): port $config{backend_port}                            ║";
    say "║  Frontend (Cro): port $config{frontend_port}                              ║";
    say "╚══════════════════════════════════════════════════════════════╝";
    
    $loop->run;
}

main() unless caller;

1;
