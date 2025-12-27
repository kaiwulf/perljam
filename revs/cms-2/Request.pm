package PerlJam::Request;
#
# PerlJam::Request - HTTP Request object
#
use strict;
use warnings;
use v5.24;

sub new {
    my ($class, $raw) = @_;
    
    return bless {
        method       => $raw->{method},
        path         => $raw->{path},
        uri          => $raw->{uri},
        query_string => $raw->{query_string},
        query        => $raw->{query}   // {},
        headers      => $raw->{headers} // {},
        cookies      => $raw->{cookies} // {},
        params       => $raw->{params}  // {},
        files        => $raw->{files}   // [],
        json         => $raw->{json},
        body         => $raw->{body},
        body_type    => $raw->{body_type},
        route_params => {},
    }, $class;
}

# Accessors
sub method       { $_[0]->{method} }
sub path         { $_[0]->{path} }
sub uri          { $_[0]->{uri} }
sub query_string { $_[0]->{query_string} }
sub body         { $_[0]->{body} }
sub body_type    { $_[0]->{body_type} }

# Headers
sub headers { $_[0]->{headers} }

sub header {
    my ($self, $name) = @_;
    return $self->{headers}{lc($name)};
}

sub content_type {
    my ($self) = @_;
    my $ct = $self->header('content-type') // '';
    $ct =~ s/;.*//;  # Strip charset etc.
    return $ct;
}

sub is_json {
    my ($self) = @_;
    return $self->content_type eq 'application/json';
}

sub is_form {
    my ($self) = @_;
    return $self->content_type eq 'application/x-www-form-urlencoded';
}

sub is_multipart {
    my ($self) = @_;
    return $self->content_type =~ /^multipart\/form-data/;
}

# Cookies
sub cookies { $_[0]->{cookies} }

sub cookie {
    my ($self, $name) = @_;
    return $self->{cookies}{$name};
}

# Query parameters
sub query { $_[0]->{query} }

sub query_param {
    my ($self, $name) = @_;
    return $self->{query}{$name};
}

# Body parameters (form data)
sub params { $_[0]->{params} }

# Route parameters
sub route_params { $_[0]->{route_params} }

sub set_route_params {
    my ($self, $params) = @_;
    $self->{route_params} = $params;
}

# Unified parameter access: route > body > query
sub param {
    my ($self, $name) = @_;
    
    return $self->{route_params}{$name}
        // $self->{params}{$name}
        // $self->{query}{$name};
}

# Get all parameters merged
sub all_params {
    my ($self) = @_;
    return {
        %{$self->{query}},
        %{$self->{params}},
        %{$self->{route_params}},
    };
}

# JSON body
sub json { $_[0]->{json} }

# File uploads
sub files { $_[0]->{files} }

sub file {
    my ($self, $name) = @_;
    for my $f (@{$self->{files}}) {
        return $f if $f->{name} eq $name;
    }
    return undef;
}

# Check if request wants JSON response
sub wants_json {
    my ($self) = @_;
    my $accept = $self->header('accept') // '';
    return $accept =~ /application\/json/;
}

# Check if AJAX request
sub is_xhr {
    my ($self) = @_;
    my $xhr = $self->header('x-requested-with') // '';
    return lc($xhr) eq 'xmlhttprequest';
}

# Client IP (handles X-Forwarded-For)
sub client_ip {
    my ($self) = @_;
    
    if (my $forwarded = $self->header('x-forwarded-for')) {
        my ($ip) = split /,/, $forwarded;
        $ip =~ s/^\s+|\s+$//g;
        return $ip;
    }
    
    return $self->header('x-real-ip');
}

1;

__END__

=head1 NAME

PerlJam::Request - HTTP Request object

=head1 SYNOPSIS

    sub handler {
        my ($req, $res) = @_;
        
        # Get route parameter
        my $id = $req->param('id');
        
        # Get form data
        my $title = $req->param('title');
        
        # Get JSON body
        my $data = $req->json;
        
        # Check content type
        if ($req->is_json) { ... }
        
        # Get uploaded file
        my $file = $req->file('avatar');
    }

=cut
