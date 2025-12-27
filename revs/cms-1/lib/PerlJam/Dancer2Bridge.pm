package PerlJam::Dancer2Bridge;
#
# PerlJam::Dancer2Bridge - Mount Dancer2 apps directly or proxy to them
#
use strict;
use warnings;
use v5.24;

use IO::Async::Loop;
use Future::AsyncAwait;
use JSON::PP;

our $json = JSON::PP->new->utf8;

sub new {
    my ($class, %options) = @_;
    
    return bless {
        mode         => $options{mode} // 'proxy',  # 'proxy' or 'mount'
        backend_host => $options{host} // 'localhost',
        backend_port => $options{port} // 5000,
        app          => $options{app},  # Dancer2 app for 'mount' mode
        loop         => $options{loop},
    }, $class;
}

# Build PSGI environment from PerlJam request
sub _build_psgi_env {
    my ($self, $req) = @_;
    
    my %env = (
        REQUEST_METHOD    => $req->method,
        SCRIPT_NAME       => '',
        PATH_INFO         => $req->path,
        QUERY_STRING      => $req->query_string // '',
        SERVER_NAME       => 'localhost',
        SERVER_PORT       => 8081,
        SERVER_PROTOCOL   => 'HTTP/1.1',
        'psgi.version'    => [1, 1],
        'psgi.url_scheme' => 'http',
        'psgi.input'      => _string_io($req->body // ''),
        'psgi.errors'     => \*STDERR,
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
    );
    
    # Convert headers to CGI format
    for my $header (keys %{$req->headers}) {
        my $cgi_name = uc($header);
        $cgi_name =~ s/-/_/g;
        
        if ($header eq 'content-type') {
            $env{CONTENT_TYPE} = $req->headers->{$header};
        } elsif ($header eq 'content-length') {
            $env{CONTENT_LENGTH} = $req->headers->{$header};
        } else {
            $env{"HTTP_$cgi_name"} = $req->headers->{$header};
        }
    }
    
    return \%env;
}

# Simple string IO for PSGI input
sub _string_io {
    my ($string) = @_;
    open my $fh, '<', \$string or die "Cannot create string IO: $!";
    return $fh;
}

# Mount mode: call Dancer2 app directly via PSGI
sub handle_mount {
    my ($self, $req, $res) = @_;
    
    my $app = $self->{app};
    return 0 unless $app;
    
    my $env = $self->_build_psgi_env($req);
    
    # Call PSGI app
    my $psgi_response;
    eval {
        $psgi_response = $app->($env);
    };
    
    if ($@) {
        warn "Dancer2 error: $@";
        $res->error(500, "Backend error");
        return 1;
    }
    
    # Convert PSGI response to PerlJam response
    my ($status, $headers, $body) = @$psgi_response;
    
    $res->status($status);
    
    # Set headers (PSGI uses arrayref of pairs)
    for (my $i = 0; $i < @$headers; $i += 2) {
        $res->header($headers->[$i], $headers->[$i + 1]);
    }
    
    # Collect body
    my $content = '';
    if (ref $body eq 'ARRAY') {
        $content = join '', @$body;
    } elsif (ref $body && $body->can('getlines')) {
        $content = join '', $body->getlines;
        $body->close if $body->can('close');
    }
    
    $res->send($content);
    return 1;
}

# Proxy mode: forward request to Dancer2 backend
sub handle_proxy {
    my ($self, $req, $res) = @_;
    
    # Build request to backend
    my $method = $req->method;
    my $path = $req->path;
    my $query = $req->query_string ? "?$req->query_string" : '';
    
    my $backend_url = "http://$self->{backend_host}:$self->{backend_port}${path}${query}";
    
    # For now, use simple HTTP client
    # In production, use IO::Async::HTTP or similar
    eval {
        require HTTP::Tiny;
        
        my $http = HTTP::Tiny->new(timeout => 30);
        
        my %options = (
            headers => {},
        );
        
        # Forward relevant headers
        for my $h (qw(content-type accept cookie authorization)) {
            if (my $v = $req->header($h)) {
                $options{headers}{$h} = $v;
            }
        }
        
        # Forward body for POST/PUT/PATCH
        if ($method =~ /^(POST|PUT|PATCH)$/) {
            $options{content} = $req->body;
        }
        
        my $response = $http->request($method, $backend_url, \%options);
        
        $res->status($response->{status});
        
        for my $header (keys %{$response->{headers}}) {
            next if lc($header) eq 'transfer-encoding';
            next if lc($header) eq 'connection';
            $res->header($header, $response->{headers}{$header});
        }
        
        $res->send($response->{content});
    };
    
    if ($@) {
        warn "Proxy error: $@";
        $res->error(502, "Backend unavailable");
    }
    
    return 1;
}

# Main dispatch
sub handle {
    my ($self, $req, $res) = @_;
    
    if ($self->{mode} eq 'mount' && $self->{app}) {
        return $self->handle_mount($req, $res);
    } else {
        return $self->handle_proxy($req, $res);
    }
}

1;

__END__

=head1 NAME

PerlJam::Dancer2Bridge - Connect PerlJam to Dancer2 backends

=head1 SYNOPSIS

    use PerlJam::Dancer2Bridge;
    
    # Proxy mode (Dancer2 runs separately)
    my $bridge = PerlJam::Dancer2Bridge->new(
        mode => 'proxy',
        host => 'localhost',
        port => 5000,
    );
    
    # Mount mode (embed Dancer2 in PerlJam)
    use MyApp;  # Dancer2 app
    my $bridge = PerlJam::Dancer2Bridge->new(
        mode => 'mount',
        app  => MyApp->to_app,
    );
    
    # In router
    $router->any('/admin/:path*' => sub {
        my ($req, $res) = @_;
        $bridge->handle($req, $res);
    });

=head1 DESCRIPTION

This module provides two integration modes:

=over

=item proxy

Forwards requests to a separate Dancer2 process. Good for development
and when you want process isolation.

=item mount

Embeds the Dancer2 app directly via PSGI. Better performance but
shares the event loop.

=back

=cut
