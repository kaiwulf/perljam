package PerlJam::Server;
#
# PerlJam::Server - HTTP server using only core Perl modules
# Uses IO::Socket::INET and IO::Select for non-blocking I/O
#
# This is a simpler alternative to IO::Async - single-threaded,
# non-blocking, suitable for low-to-medium traffic sites.
#
use strict;
use warnings;
use v5.14;

use IO::Socket::INET;
use IO::Select;
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use POSIX qw(strftime);

use PerlJam::Util qw(http_date mime_type uri_unescape html_escape);

our $VERSION = '0.2.0';

#═══════════════════════════════════════════════════════════════════════════════
# Constructor
#═══════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %options) = @_;
    
    my $self = bless {
        host           => $options{host} // '0.0.0.0',
        port           => $options{port} // 8080,
        document_root  => $options{document_root} // 'public',
        max_body_size  => $options{max_body_size} // 10 * 1024 * 1024,
        timeout        => $options{timeout} // 30,
        index_files    => $options{index_files} // ['index.html', 'index.htm'],
        
        routes         => [],
        middleware     => [],
        
        # Runtime state
        server         => undef,
        select         => undef,
        clients        => {},  # socket -> { buffer, state, ... }
        running        => 0,
    }, $class;
    
    return $self;
}

#═══════════════════════════════════════════════════════════════════════════════
# Routing
#═══════════════════════════════════════════════════════════════════════════════

sub get    { shift->_add_route('GET',    @_) }
sub post   { shift->_add_route('POST',   @_) }
sub put    { shift->_add_route('PUT',    @_) }
sub delete { shift->_add_route('DELETE', @_) }
sub any    { shift->_add_route('ANY',    @_) }

sub _add_route {
    my ($self, $method, $pattern, $handler) = @_;
    
    # Convert pattern to regex
    my @param_names;
    my $regex = $pattern;
    $regex =~ s{:(\w+)(\*)?}{
        push @param_names, $1;
        $2 ? '(.+)' : '([^/]+)'
    }ge;
    $regex = qr{^$regex$};
    
    push @{$self->{routes}}, {
        method  => $method,
        pattern => $pattern,
        regex   => $regex,
        params  => \@param_names,
        handler => $handler,
    };
    
    return $self;
}

sub use {
    my ($self, $middleware) = @_;
    push @{$self->{middleware}}, $middleware;
    return $self;
}

#═══════════════════════════════════════════════════════════════════════════════
# Server Lifecycle
#═══════════════════════════════════════════════════════════════════════════════

sub run {
    my ($self) = @_;
    
    $self->{server} = IO::Socket::INET->new(
        LocalAddr => $self->{host},
        LocalPort => $self->{port},
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
        Blocking  => 0,
    ) or die "Cannot create server: $!";
    
    $self->{select} = IO::Select->new($self->{server});
    $self->{running} = 1;
    
    $self->_log("Server started on http://$self->{host}:$self->{port}");
    $self->_log("Document root: $self->{document_root}");
    
    local $SIG{INT} = sub {
        $self->_log("Shutting down...");
        $self->{running} = 0;
    };
    
    while ($self->{running}) {
        $self->_poll();
    }
    
    $self->{server}->close;
    $self->_log("Server stopped");
}

sub _poll {
    my ($self) = @_;
    
    my @ready = $self->{select}->can_read(0.1);
    
    for my $socket (@ready) {
        if ($socket == $self->{server}) {
            $self->_accept_connection();
        } else {
            $self->_read_from_client($socket);
        }
    }
    
    # Check for clients ready to write
    my @writers = $self->{select}->can_write(0);
    for my $socket (@writers) {
        next if $socket == $self->{server};
        $self->_write_to_client($socket);
    }
    
    # Timeout old connections
    my $now = time();
    for my $socket (keys %{$self->{clients}}) {
        my $client = $self->{clients}{$socket};
        if ($now - $client->{last_activity} > $self->{timeout}) {
            $self->_close_client($socket);
        }
    }
}

sub _accept_connection {
    my ($self) = @_;
    
    my $client = $self->{server}->accept or return;
    $client->blocking(0);
    
    # Disable Nagle's algorithm for lower latency
    setsockopt($client, IPPROTO_TCP, TCP_NODELAY, 1);
    
    $self->{select}->add($client);
    
    $self->{clients}{$client} = {
        socket        => $client,
        buffer        => '',
        write_buffer  => '',
        state         => 'reading_headers',
        last_activity => time(),
        peer          => $client->peerhost // 'unknown',
    };
    
    $self->_log("Connection from $self->{clients}{$client}{peer}");
}

sub _close_client {
    my ($self, $socket) = @_;
    
    $self->{select}->remove($socket);
    delete $self->{clients}{$socket};
    $socket->close if ref $socket;
}

#═══════════════════════════════════════════════════════════════════════════════
# Reading & Parsing Requests
#═══════════════════════════════════════════════════════════════════════════════

sub _read_from_client {
    my ($self, $socket) = @_;
    
    my $client = $self->{clients}{$socket} or return;
    $client->{last_activity} = time();
    
    my $data;
    my $bytes = $socket->sysread($data, 8192);
    
    if (!defined $bytes) {
        return if $! == POSIX::EAGAIN || $! == POSIX::EWOULDBLOCK;
        $self->_close_client($socket);
        return;
    }
    
    if ($bytes == 0) {
        $self->_close_client($socket);
        return;
    }
    
    $client->{buffer} .= $data;
    
    # State machine
    if ($client->{state} eq 'reading_headers') {
        if ($client->{buffer} =~ s/^(.*?\r?\n\r?\n)//s) {
            my $headers = $1;
            my $request = $self->_parse_headers($headers);
            
            unless ($request) {
                $self->_send_error($client, 400, 'Bad Request');
                return;
            }
            
            $client->{request} = $request;
            
            my $content_length = $request->{headers}{'content-length'} // 0;
            
            if ($content_length > $self->{max_body_size}) {
                $self->_send_error($client, 413, 'Payload Too Large');
                return;
            }
            
            if ($content_length > 0) {
                $client->{state} = 'reading_body';
                $client->{body_remaining} = $content_length;
                $client->{request}{body} = '';
            } else {
                $self->_handle_request($client);
            }
        }
    }
    
    if ($client->{state} eq 'reading_body') {
        my $take = length($client->{buffer});
        $take = $client->{body_remaining} if $take > $client->{body_remaining};
        
        $client->{request}{body} .= substr($client->{buffer}, 0, $take, '');
        $client->{body_remaining} -= $take;
        
        if ($client->{body_remaining} <= 0) {
            $self->_handle_request($client);
        }
    }
}

sub _parse_headers {
    my ($self, $raw) = @_;
    
    my @lines = split /\r?\n/, $raw;
    my $request_line = shift @lines;
    
    return unless $request_line =~ /^([A-Z]+)\s+(\S+)\s+HTTP\/1\.[01]$/;
    
    my ($method, $uri) = ($1, $2);
    my ($path, $query_string) = split /\?/, $uri, 2;
    
    my %headers;
    for my $line (@lines) {
        last if $line eq '';
        if ($line =~ /^([^:]+):\s*(.*)$/) {
            $headers{lc($1)} = $2;
        }
    }
    
    return {
        method       => $method,
        uri          => $uri,
        path         => $path,
        query_string => $query_string // '',
        headers      => \%headers,
    };
}

#═══════════════════════════════════════════════════════════════════════════════
# Writing Responses
#═══════════════════════════════════════════════════════════════════════════════

sub _write_to_client {
    my ($self, $socket) = @_;
    
    my $client = $self->{clients}{$socket} or return;
    return unless length($client->{write_buffer});
    
    my $bytes = $socket->syswrite($client->{write_buffer});
    
    if (!defined $bytes) {
        return if $! == POSIX::EAGAIN || $! == POSIX::EWOULDBLOCK;
        $self->_close_client($socket);
        return;
    }
    
    substr($client->{write_buffer}, 0, $bytes, '');
    
    # Check if done writing
    if (length($client->{write_buffer}) == 0) {
        if ($client->{close_after_write}) {
            $self->_close_client($socket);
        } else {
            # Reset for next request (keep-alive)
            $client->{state} = 'reading_headers';
            $client->{request} = undef;
        }
    }
}

sub _send_response {
    my ($self, $client, $status, $headers, $body) = @_;
    
    my %status_text = (
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
        500 => 'Internal Server Error',
    );
    
    $body //= '';
    $headers //= {};
    
    $headers->{'Content-Length'} //= length($body);
    $headers->{'Content-Type'} //= 'text/html; charset=utf-8';
    $headers->{'Server'} //= "perljam/$VERSION";
    $headers->{'Date'} //= http_date();
    $headers->{'Connection'} //= 'keep-alive';
    
    my $response = "HTTP/1.1 $status " . ($status_text{$status} // 'Unknown') . "\r\n";
    for my $name (keys %$headers) {
        $response .= "$name: $headers->{$name}\r\n";
    }
    $response .= "\r\n";
    $response .= $body;
    
    $client->{write_buffer} .= $response;
    $client->{close_after_write} = ($headers->{'Connection'} eq 'close');
    
    $self->_log("$client->{peer} $client->{request}{method} $client->{request}{path} -> $status");
}

sub _send_error {
    my ($self, $client, $status, $message) = @_;
    
    my $body = <<"HTML";
<!DOCTYPE html>
<html>
<head><title>$status Error</title></head>
<body>
<h1>$status $message</h1>
<p>perljam/$VERSION</p>
</body>
</html>
HTML

    $self->_send_response($client, $status, { 'Connection' => 'close' }, $body);
}

#═══════════════════════════════════════════════════════════════════════════════
# Request Handling
#═══════════════════════════════════════════════════════════════════════════════

sub _handle_request {
    my ($self, $client) = @_;
    
    my $request = $client->{request};
    
    # Parse body if present
    $self->_parse_body($request);
    
    # Build request object
    my $req = PerlJam::Server::Request->new($request);
    my $res = PerlJam::Server::Response->new($self, $client);
    
    # Run middleware
    for my $mw (@{$self->{middleware}}) {
        my $result = $mw->($req, $res);
        return if $res->{sent};
        return unless $result;
    }
    
    # Find matching route
    for my $route (@{$self->{routes}}) {
        next unless $route->{method} eq $request->{method} || $route->{method} eq 'ANY';
        
        if (my @captures = $request->{path} =~ $route->{regex}) {
            my %params;
            for my $i (0 .. $#{$route->{params}}) {
                $params{$route->{params}[$i]} = $captures[$i];
            }
            $req->{route_params} = \%params;
            
            eval { $route->{handler}->($req, $res) };
            if ($@) {
                $self->_log("Error: $@");
                $res->error(500, 'Internal Server Error') unless $res->{sent};
            }
            return;
        }
    }
    
    # Try static file
    $self->_serve_static($client, $request);
}

sub _parse_body {
    my ($self, $request) = @_;
    
    my $body = $request->{body} // '';
    my $ct = $request->{headers}{'content-type'} // '';
    
    if ($ct =~ /application\/x-www-form-urlencoded/i) {
        $request->{params} = $self->_parse_urlencoded($body);
    }
    elsif ($ct =~ /application\/json/i) {
        eval {
            require JSON::PP;
            $request->{json} = JSON::PP::decode_json($body);
        };
    }
    elsif ($ct =~ /multipart\/form-data.*boundary=(.+)/i) {
        my ($params, $files) = $self->_parse_multipart($body, $1);
        $request->{params} = $params;
        $request->{files} = $files;
    }
}

sub _parse_urlencoded {
    my ($self, $body) = @_;
    my %params;
    
    for my $pair (split /&/, $body) {
        my ($key, $val) = split /=/, $pair, 2;
        $key = uri_unescape($key // '');
        $val = uri_unescape($val // '');
        $params{$key} = $val;
    }
    
    return \%params;
}

sub _parse_multipart {
    my ($self, $body, $boundary) = @_;
    my %params;
    my @files;
    
    $boundary =~ s/^["']|["']$//g;
    
    for my $part (split /--\Q$boundary\E/, $body) {
        next if $part =~ /^--/ || $part !~ /\S/;
        
        my ($headers, $content) = split /\r?\n\r?\n/, $part, 2;
        next unless defined $content;
        $content =~ s/\r?\n$//;
        
        my ($name) = $headers =~ /name="([^"]+)"/;
        my ($filename) = $headers =~ /filename="([^"]+)"/;
        
        if ($filename) {
            my ($ct) = $headers =~ /Content-Type:\s*(\S+)/i;
            push @files, {
                name         => $name,
                filename     => $filename,
                content_type => $ct // 'application/octet-stream',
                content      => $content,
                size         => length($content),
            };
        } elsif ($name) {
            $params{$name} = $content;
        }
    }
    
    return (\%params, \@files);
}

#═══════════════════════════════════════════════════════════════════════════════
# Static Files
#═══════════════════════════════════════════════════════════════════════════════

sub _serve_static {
    my ($self, $client, $request) = @_;
    
    return $self->_send_error($client, 405, 'Method Not Allowed')
        unless $request->{method} =~ /^(GET|HEAD)$/;
    
    my $path = $request->{path};
    $path =~ s/^\/+//;
    $path = uri_unescape($path);
    $path =~ s/\.\.//g;  # Security
    
    my $file = "$self->{document_root}/$path";
    
    # Check for index files
    if (-d $file) {
        for my $index (@{$self->{index_files}}) {
            my $test = "$file/$index";
            if (-f $test) {
                $file = $test;
                last;
            }
        }
    }
    
    unless (-f $file && -r $file) {
        return $self->_send_error($client, 404, 'Not Found');
    }
    
    my @stat = stat($file);
    my $size = $stat[7];
    my $mtime = $stat[9];
    
    my $headers = {
        'Content-Type'  => mime_type($file),
        'Last-Modified' => http_date($mtime),
        'Cache-Control' => 'public, max-age=3600',
    };
    
    if ($request->{method} eq 'HEAD') {
        $headers->{'Content-Length'} = $size;
        $self->_send_response($client, 200, $headers, '');
        return;
    }
    
    open my $fh, '<:raw', $file or return $self->_send_error($client, 500, 'Read Error');
    local $/;
    my $content = <$fh>;
    close $fh;
    
    $self->_send_response($client, 200, $headers, $content);
}

#═══════════════════════════════════════════════════════════════════════════════
# Logging
#═══════════════════════════════════════════════════════════════════════════════

sub _log {
    my ($self, $message) = @_;
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    say STDERR "[$timestamp] $message";
}

#═══════════════════════════════════════════════════════════════════════════════
# Request Object
#═══════════════════════════════════════════════════════════════════════════════

package PerlJam::Server::Request;

sub new {
    my ($class, $raw) = @_;
    return bless {
        method       => $raw->{method},
        path         => $raw->{path},
        uri          => $raw->{uri},
        query_string => $raw->{query_string},
        headers      => $raw->{headers},
        params       => $raw->{params} // {},
        files        => $raw->{files} // [],
        json         => $raw->{json},
        body         => $raw->{body},
        route_params => {},
    }, $class;
}

sub method { $_[0]->{method} }
sub path   { $_[0]->{path} }
sub header { $_[0]->{headers}{lc($_[1])} }
sub json   { $_[0]->{json} }
sub files  { $_[0]->{files} }

sub param {
    my ($self, $name) = @_;
    return $self->{route_params}{$name}
        // $self->{params}{$name};
}

#═══════════════════════════════════════════════════════════════════════════════
# Response Object
#═══════════════════════════════════════════════════════════════════════════════

package PerlJam::Server::Response;

sub new {
    my ($class, $server, $client) = @_;
    return bless {
        server  => $server,
        client  => $client,
        status  => 200,
        headers => {},
        sent    => 0,
    }, $class;
}

sub status {
    my ($self, $code) = @_;
    $self->{status} = $code;
    return $self;
}

sub header {
    my ($self, $name, $value) = @_;
    $self->{headers}{$name} = $value;
    return $self;
}

sub send {
    my ($self, $body) = @_;
    return if $self->{sent};
    $self->{sent} = 1;
    $self->{server}->_send_response($self->{client}, $self->{status}, $self->{headers}, $body);
}

sub json {
    my ($self, $data) = @_;
    require JSON::PP;
    $self->{headers}{'Content-Type'} = 'application/json';
    $self->send(JSON::PP::encode_json($data));
}

sub html {
    my ($self, $content) = @_;
    $self->{headers}{'Content-Type'} = 'text/html; charset=utf-8';
    $self->send($content);
}

sub redirect {
    my ($self, $url, $status) = @_;
    $self->{status} = $status // 302;
    $self->{headers}{Location} = $url;
    $self->send('');
}

sub error {
    my ($self, $status, $message) = @_;
    $self->{status} = $status;
    $self->{server}->_send_error($self->{client}, $status, $message);
    $self->{sent} = 1;
}

1;

__END__

=head1 NAME

PerlJam::Server - HTTP server using only core Perl modules

=head1 SYNOPSIS

    use PerlJam::Server;
    
    my $server = PerlJam::Server->new(
        port          => 8080,
        document_root => 'public',
    );
    
    $server->get('/' => sub {
        my ($req, $res) = @_;
        $res->html('<h1>Hello World</h1>');
    });
    
    $server->get('/api/users/:id' => sub {
        my ($req, $res) = @_;
        my $id = $req->param('id');
        $res->json({ user_id => $id });
    });
    
    $server->post('/api/data' => sub {
        my ($req, $res) = @_;
        my $data = $req->json;
        $res->status(201)->json({ received => $data });
    });
    
    $server->run;

=head1 DESCRIPTION

A complete HTTP server using only core Perl modules (IO::Socket::INET, 
IO::Select). No CPAN dependencies required.

Features:
- Non-blocking I/O with keep-alive support
- URL routing with parameters
- Static file serving
- JSON and form data parsing
- File upload handling
- Middleware support

=cut
