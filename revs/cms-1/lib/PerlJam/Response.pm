package PerlJam::Response;
#
# PerlJam::Response - HTTP Response builder
#
use strict;
use warnings;
use v5.24;

use HTTP::Date qw(time2str);
use JSON::PP;

our $json = JSON::PP->new->utf8->pretty;

our %STATUS_MESSAGES = (
    200 => 'OK',
    201 => 'Created',
    204 => 'No Content',
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    304 => 'Not Modified',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    409 => 'Conflict',
    413 => 'Payload Too Large',
    415 => 'Unsupported Media Type',
    422 => 'Unprocessable Entity',
    429 => 'Too Many Requests',
    500 => 'Internal Server Error',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
);

sub new {
    my ($class, $stream) = @_;
    
    return bless {
        stream       => $stream,
        status       => 200,
        headers      => {},
        cookies      => [],
        sent         => 0,
    }, $class;
}

# Chainable setters
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

sub content_type {
    my ($self, $type) = @_;
    $self->{headers}{'Content-Type'} = $type;
    return $self;
}

# Cookie setting
sub cookie {
    my ($self, $name, $value, %options) = @_;
    
    my $cookie = "$name=$value";
    $cookie .= "; Path=" . ($options{path} // '/');
    $cookie .= "; HttpOnly" if $options{httponly} // 1;
    $cookie .= "; Secure" if $options{secure};
    $cookie .= "; SameSite=" . ($options{samesite} // 'Lax');
    
    if (my $max_age = $options{max_age}) {
        $cookie .= "; Max-Age=$max_age";
    }
    if (my $expires = $options{expires}) {
        $cookie .= "; Expires=" . time2str($expires);
    }
    
    push @{$self->{cookies}}, $cookie;
    return $self;
}

sub clear_cookie {
    my ($self, $name, %options) = @_;
    return $self->cookie($name, '', max_age => 0, %options);
}

# Build and send response
sub _build_headers {
    my ($self, $content_length) = @_;
    
    my $status_text = $STATUS_MESSAGES{$self->{status}} // 'Unknown';
    
    my @headers = (
        "HTTP/1.1 $self->{status} $status_text",
        "Server: perljam",
        "Date: " . time2str(time()),
        "Connection: keep-alive",
    );
    
    # Add custom headers
    for my $name (keys %{$self->{headers}}) {
        push @headers, "$name: $self->{headers}{$name}";
    }
    
    # Add cookies
    for my $cookie (@{$self->{cookies}}) {
        push @headers, "Set-Cookie: $cookie";
    }
    
    # Content-Length
    push @headers, "Content-Length: $content_length" if defined $content_length;
    
    return join("\r\n", @headers) . "\r\n\r\n";
}

sub send {
    my ($self, $body) = @_;
    $body //= '';
    
    return if $self->{sent};
    $self->{sent} = 1;
    
    # Default content type
    $self->{headers}{'Content-Type'} //= 'text/html; charset=utf-8';
    
    my $headers = $self->_build_headers(length($body));
    $self->{stream}->write($headers . $body);
    
    return $self;
}

sub is_sent { $_[0]->{sent} }

# Convenience methods
sub json {
    my ($self, $data) = @_;
    
    $self->{headers}{'Content-Type'} = 'application/json';
    my $body = $json->encode($data);
    
    return $self->send($body);
}

sub text {
    my ($self, $text) = @_;
    
    $self->{headers}{'Content-Type'} = 'text/plain; charset=utf-8';
    return $self->send($text);
}

sub html {
    my ($self, $html) = @_;
    
    $self->{headers}{'Content-Type'} = 'text/html; charset=utf-8';
    return $self->send($html);
}

sub redirect {
    my ($self, $url, $status) = @_;
    $status //= 302;
    
    $self->{status} = $status;
    $self->{headers}{Location} = $url;
    
    my $body = qq{<html><body>Redirecting to <a href="$url">$url</a></body></html>};
    return $self->send($body);
}

sub not_found {
    my ($self, $message) = @_;
    $message //= 'Not Found';
    
    $self->{status} = 404;
    return $self->html(<<"HTML");
<!DOCTYPE html>
<html>
<head><title>404 Not Found</title></head>
<body>
<h1>404 Not Found</h1>
<p>$message</p>
</body>
</html>
HTML
}

sub error {
    my ($self, $status, $message) = @_;
    $status //= 500;
    $message //= $STATUS_MESSAGES{$status} // 'Error';
    
    $self->{status} = $status;
    return $self->html(<<"HTML");
<!DOCTYPE html>
<html>
<head><title>$status $STATUS_MESSAGES{$status}</title></head>
<body>
<h1>$status $STATUS_MESSAGES{$status}</h1>
<p>$message</p>
</body>
</html>
HTML
}

# Stream file
sub send_file {
    my ($self, $path, %options) = @_;
    
    unless (-f $path && -r $path) {
        return $self->not_found("File not found");
    }
    
    my @stat = stat($path);
    my $size = $stat[7];
    
    # Determine content type
    my $content_type = $options{content_type};
    unless ($content_type) {
        eval { require File::MimeInfo; };
        if ($@) {
            $content_type = 'application/octet-stream';
        } else {
            $content_type = File::MimeInfo::mimetype($path) // 'application/octet-stream';
        }
    }
    
    # Set headers
    $self->{headers}{'Content-Type'} = $content_type;
    $self->{headers}{'Content-Length'} = $size;
    
    if (my $filename = $options{filename}) {
        $self->{headers}{'Content-Disposition'} = qq{attachment; filename="$filename"};
    }
    
    # Read and send
    open my $fh, '<:raw', $path or return $self->error(500, "Cannot read file");
    local $/;
    my $content = <$fh>;
    close $fh;
    
    return $self->send($content);
}

1;

__END__

=head1 NAME

PerlJam::Response - HTTP Response builder

=head1 SYNOPSIS

    sub handler {
        my ($req, $res) = @_;
        
        # JSON response
        $res->json({ success => 1, data => \@items });
        
        # HTML response
        $res->html('<h1>Hello World</h1>');
        
        # Custom status
        $res->status(201)->json({ id => 42 });
        
        # Set cookie
        $res->cookie('session', $token, max_age => 86400);
        
        # Redirect
        $res->redirect('/dashboard');
        
        # Send file
        $res->send_file('/path/to/file.pdf', filename => 'report.pdf');
    }

=cut
