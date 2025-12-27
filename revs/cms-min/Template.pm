package PerlJam::Template;
#
# PerlJam::Template - Minimal template engine (replaces Template Toolkit)
#
# Syntax:
#   <% $variable %>           - interpolate variable
#   <% expr %>                - evaluate expression  
#   <%if condition %> ... <%end%>
#   <%for item in list %> ... <%end%>
#   <%include 'file.tt' %>
#   <%raw%> ... <%endraw%>    - no escaping
#
use strict;
use warnings;
use v5.14;

use File::Spec;
use PerlJam::Util qw(html_escape);

sub new {
    my ($class, %options) = @_;
    
    return bless {
        path       => $options{path} // ['templates'],
        cache      => {},
        auto_escape => $options{auto_escape} // 1,
        layouts    => $options{layouts} // 'layouts',
    }, $class;
}

# Load template from file
sub _load {
    my ($self, $name) = @_;
    
    return $self->{cache}{$name} if exists $self->{cache}{$name};
    
    for my $dir (@{$self->{path}}) {
        my $file = File::Spec->catfile($dir, $name);
        if (-f $file) {
            open my $fh, '<:utf8', $file or die "Cannot read $file: $!";
            local $/;
            my $content = <$fh>;
            close $fh;
            
            $self->{cache}{$name} = $content;
            return $content;
        }
    }
    
    die "Template not found: $name";
}

# Compile template to Perl code
sub _compile {
    my ($self, $template) = @_;
    
    my $code = 'my $__out = "";' . "\n";
    
    # Process raw blocks first (no escaping inside)
    $template =~ s/<%raw%>(.*?)<%endraw%>/_raw_block($1)/gse;
    
    my $pos = 0;
    while ($template =~ /<%(.+?)%>/gs) {
        my $tag = $1;
        my $before = substr($template, $pos, $-[0] - $pos);
        $pos = $+[0];
        
        # Add literal text
        if ($before ne '') {
            $before =~ s/\\/\\\\/g;
            $before =~ s/'/\\'/g;
            $code .= '$__out .= \'' . $before . "';\n";
        }
        
        # Process tag
        $tag =~ s/^\s+|\s+$//g;
        
        if ($tag =~ /^if\s+(.+)$/) {
            $code .= "if ($1) {\n";
        }
        elsif ($tag =~ /^elsif\s+(.+)$/) {
            $code .= "} elsif ($1) {\n";
        }
        elsif ($tag eq 'else') {
            $code .= "} else {\n";
        }
        elsif ($tag =~ /^for\s+(\w+)\s+in\s+(.+)$/) {
            my ($var, $list) = ($1, $2);
            $code .= "for my \$$var (\@{$list}) {\n";
        }
        elsif ($tag =~ /^foreach\s+(\w+)\s+(.+)$/) {
            my ($var, $list) = ($1, $2);
            $code .= "for my \$$var ($list) {\n";
        }
        elsif ($tag eq 'end' || $tag eq 'endif' || $tag eq 'endfor') {
            $code .= "}\n";
        }
        elsif ($tag =~ /^include\s+['"]?([^'"]+)['"]?$/) {
            $code .= '$__out .= $self->_render_include("' . $1 . '", \%vars);' . "\n";
        }
        elsif ($tag =~ /^=\s*(.+)$/) {
            # Raw output (no escaping)
            $code .= '$__out .= (' . $1 . ') // "";' . "\n";
        }
        elsif ($tag =~ /^#/) {
            # Comment, ignore
        }
        else {
            # Expression - escape by default
            if ($self->{auto_escape}) {
                $code .= '$__out .= PerlJam::Util::html_escape((' . $tag . ') // "");' . "\n";
            } else {
                $code .= '$__out .= (' . $tag . ') // "";' . "\n";
            }
        }
    }
    
    # Add remaining literal text
    my $after = substr($template, $pos);
    if ($after ne '') {
        $after =~ s/\\/\\\\/g;
        $after =~ s/'/\\'/g;
        $code .= '$__out .= \'' . $after . "';\n";
    }
    
    $code .= 'return $__out;';
    
    return $code;
}

sub _raw_block {
    my ($content) = @_;
    $content =~ s/'/\\'/g;
    return "<%=\n'$content'\n%>";
}

sub _render_include {
    my ($self, $name, $vars_ref) = @_;
    my $template = $self->_load($name);
    return $self->_render_string($template, $vars_ref);
}

sub _render_string {
    my ($self, $template, $vars_ref) = @_;
    
    my $code = $self->_compile($template);
    
    # Build variable declarations
    my $var_decl = '';
    for my $key (keys %$vars_ref) {
        next unless $key =~ /^\w+$/;
        $var_decl .= "my \$$key = \$vars{'$key'};\n";
    }
    
    my $full_code = "sub { my \%vars = \@_;\n$var_decl\n$code\n}";
    
    my $sub = eval $full_code;
    if ($@) {
        die "Template compilation error: $@\nCode:\n$full_code";
    }
    
    return $sub->(%$vars_ref);
}

# Main render method
sub render {
    my ($self, $name, $vars) = @_;
    $vars //= {};
    
    my $template = $self->_load($name);
    
    # Check for layout
    my $layout;
    if ($template =~ /<%\s*layout\s+['"]?([^'"]+)['"]?\s*%>/) {
        $layout = $1;
        $template =~ s/<%\s*layout\s+['"]?[^'"]+['"]?\s*%>//g;
    }
    
    my $content = $self->_render_string($template, $vars);
    
    # Wrap in layout if specified
    if ($layout) {
        my $layout_file = File::Spec->catfile($self->{layouts}, $layout);
        $vars->{content} = $content;
        $content = $self->render($layout_file, $vars);
    }
    
    return $content;
}

# Render string directly (no file)
sub render_string {
    my ($self, $template, $vars) = @_;
    $vars //= {};
    return $self->_render_string($template, $vars);
}

1;

__END__

=head1 NAME

PerlJam::Template - Minimal template engine

=head1 SYNOPSIS

    my $tmpl = PerlJam::Template->new(path => ['views']);
    
    my $html = $tmpl->render('page.tt', {
        title => 'Hello',
        items => [1, 2, 3],
    });

=head1 TEMPLATE SYNTAX

    <h1><% $title %></h1>
    
    <%if $logged_in %>
        Welcome, <% $username %>!
    <%else%>
        Please log in.
    <%end%>
    
    <ul>
    <%for item in $items %>
        <li><% $item %></li>
    <%end%>
    </ul>
    
    <%# This is a comment %>
    
    <%= $raw_html %>  <!-- No escaping -->
    
    <%include 'header.tt' %>

=cut
