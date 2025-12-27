package PerlJam::Router;
#
# PerlJam::Router - Flexible routing with path parameters and middleware
#
use strict;
use warnings;
use v5.24;

sub new {
    my ($class) = @_;
    return bless {
        routes     => [],
        middleware => [],
        prefix     => '',
    }, $class;
}

# Register middleware
sub use {
    my ($self, $middleware) = @_;
    push @{$self->{middleware}}, $middleware;
    return $self;
}

# Route group with prefix
sub group {
    my ($self, $prefix, $callback) = @_;
    
    my $old_prefix = $self->{prefix};
    $self->{prefix} = $old_prefix . $prefix;
    
    $callback->($self);
    
    $self->{prefix} = $old_prefix;
    
    return $self;
}

# Convert route pattern to regex
sub _compile_pattern {
    my ($pattern) = @_;
    
    my @param_names;
    
    # Replace :param with capture groups
    my $regex = $pattern;
    $regex =~ s{:(\w+)(\*)?}{
        push @param_names, $1;
        $2 ? '(.+)' : '([^/]+)'
    }ge;
    
    # Escape special chars (except our captures)
    $regex =~ s{([.+?^\${}()|])}{\\$1}g unless $regex =~ /\(/;
    
    return (qr{^$regex$}, \@param_names);
}

# Register a route
sub _add_route {
    my ($self, $method, $pattern, $handler) = @_;
    
    my $full_pattern = $self->{prefix} . $pattern;
    my ($regex, $params) = _compile_pattern($full_pattern);
    
    push @{$self->{routes}}, {
        method  => $method,
        pattern => $full_pattern,
        regex   => $regex,
        params  => $params,
        handler => $handler,
    };
    
    return $self;
}

# HTTP method shortcuts
sub get    { shift->_add_route('GET',    @_) }
sub post   { shift->_add_route('POST',   @_) }
sub put    { shift->_add_route('PUT',    @_) }
sub patch  { shift->_add_route('PATCH',  @_) }
sub delete { shift->_add_route('DELETE', @_) }
sub head   { shift->_add_route('HEAD',   @_) }

sub any {
    my ($self, $pattern, $handler) = @_;
    for my $method (qw(GET POST PUT PATCH DELETE HEAD OPTIONS)) {
        $self->_add_route($method, $pattern, $handler);
    }
    return $self;
}

# Dispatch request to matching route
sub dispatch {
    my ($self, $req, $res) = @_;
    
    my $path   = $req->path;
    my $method = $req->method;
    
    # Run middleware chain
    for my $mw (@{$self->{middleware}}) {
        my $result = $mw->($req, $res);
        return 1 if $res->is_sent;  # Middleware sent response
        return 0 if defined $result && !$result;  # Middleware rejected
    }
    
    # Find matching route
    for my $route (@{$self->{routes}}) {
        next unless $route->{method} eq $method || $route->{method} eq 'ANY';
        
        if (my @captures = $path =~ $route->{regex}) {
            # Extract named params
            my %params;
            for my $i (0 .. $#{$route->{params}}) {
                $params{$route->{params}[$i]} = $captures[$i];
            }
            $req->set_route_params(\%params);
            
            # Call handler
            eval {
                $route->{handler}->($req, $res);
            };
            
            if ($@) {
                warn "Route error: $@";
                $res->status(500)->send("Internal Server Error");
            }
            
            return 1;
        }
    }
    
    return 0;  # No route matched
}

# Debug: list all routes
sub routes {
    my ($self) = @_;
    return map { "$_->{method} $_->{pattern}" } @{$self->{routes}};
}

1;

__END__

=head1 NAME

PerlJam::Router - Flexible HTTP request router

=head1 SYNOPSIS

    my $router = PerlJam::Router->new;
    
    $router->get('/users/:id' => sub {
        my ($req, $res) = @_;
        my $user_id = $req->param('id');
        $res->json({ user_id => $user_id });
    });
    
    $router->post('/posts' => sub {
        my ($req, $res) = @_;
        my $data = $req->json;
        # Create post...
        $res->status(201)->json({ success => 1 });
    });
    
    # Route groups
    $router->group('/api/v1' => sub {
        my ($r) = @_;
        $r->get('/status' => sub { ... });
    });

=head1 ROUTE PATTERNS

    /users           - Exact match
    /users/:id       - Named parameter (matches single segment)
    /files/:path*    - Wildcard parameter (matches remaining path)

=cut
