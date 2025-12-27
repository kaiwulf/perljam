package CMS::Backend;
#
# CMS::Backend - Dancer2 admin backend for OpenCy CMS
#
use Dancer2;
use Dancer2::Plugin::Database;
use Text::Markdown 'markdown';
use HTML::Escape qw(escape_html);
use JSON::PP;
use Digest::SHA qw(sha256_hex);

our $VERSION = '0.1.0';

# Configuration
set serializer => 'JSON';
set session    => 'Simple';
set template   => 'template_toolkit';

# ═══════════════════════════════════════════════════════════════════════════════
# Authentication Helpers
# ═══════════════════════════════════════════════════════════════════════════════

sub current_user {
    my $user_id = session('user_id') or return;
    return database->quick_select('users', { id => $user_id });
}

sub require_login {
    my $user = current_user();
    unless ($user) {
        if (request->is_ajax || request->content_type =~ /json/) {
            send_error('Unauthorized', 401);
        } else {
            redirect '/admin/login?return=' . uri_escape(request->path);
        }
    }
    return $user;
}

sub require_role {
    my ($role) = @_;
    my $user = require_login();
    return 1 if $user->{role} eq 'admin';
    return 1 if $user->{role} eq $role;
    send_error('Forbidden', 403);
}

# ═══════════════════════════════════════════════════════════════════════════════
# Authentication Routes
# ═══════════════════════════════════════════════════════════════════════════════

get '/admin/login' => sub {
    template 'login', {
        return_url => query_parameters->get('return') // '/admin',
    };
};

post '/admin/login' => sub {
    my $username = body_parameters->get('username');
    my $password = body_parameters->get('password');
    my $return_url = body_parameters->get('return') // '/admin';
    
    my $user = database->quick_select('users', { username => $username });
    
    # Simple password check (use Argon2 in production)
    my $password_hash = sha256_hex($password);
    
    if ($user && $user->{password_hash} eq $password_hash) {
        session user_id => $user->{id};
        session username => $user->{username};
        session role => $user->{role};
        
        redirect $return_url;
    } else {
        template 'login', {
            error => 'Invalid username or password',
            username => $username,
        };
    }
};

get '/admin/logout' => sub {
    app->destroy_session;
    redirect '/admin/login';
};

# ═══════════════════════════════════════════════════════════════════════════════
# Dashboard
# ═══════════════════════════════════════════════════════════════════════════════

get '/admin' => sub {
    my $user = require_login();
    
    my $recent_posts = database->quick_select_all('posts',
        { author_id => $user->{id} },
        { order_by => { desc => 'updated_at' }, limit => 10 }
    );
    
    my $recent_pages = database->quick_select_all('pages',
        {},
        { order_by => { desc => 'updated_at' }, limit => 10 }
    );
    
    template 'dashboard', {
        user => $user,
        posts => $recent_posts,
        pages => $recent_pages,
    };
};

# ═══════════════════════════════════════════════════════════════════════════════
# Blog Posts CRUD
# ═══════════════════════════════════════════════════════════════════════════════

get '/admin/posts' => sub {
    require_role('author');
    
    my @posts = database->quick_select_all('posts', {},
        { order_by => { desc => 'updated_at' } }
    );
    
    template 'posts/list', { posts => \@posts };
};

get '/admin/posts/new' => sub {
    require_role('author');
    template 'posts/editor', { post => {}, action => 'create' };
};

post '/admin/posts' => sub {
    require_role('author');
    my $user = current_user();
    
    my $markdown = body_parameters->get('content_markdown') // '';
    my $html = markdown($markdown);
    my $title = body_parameters->get('title') // 'Untitled';
    my $slug = _slugify($title);
    
    database->quick_insert('posts', {
        title            => $title,
        slug             => $slug,
        excerpt          => body_parameters->get('excerpt'),
        content_markdown => $markdown,
        content_html     => $html,
        author_id        => $user->{id},
        published        => body_parameters->get('published') ? 1 : 0,
        created_at       => \'NOW()',
        updated_at       => \'NOW()',
    });
    
    if (request->is_ajax) {
        return { success => 1, slug => $slug };
    }
    redirect '/admin/posts';
};

get '/admin/posts/:id/edit' => sub {
    require_role('author');
    
    my $post = database->quick_select('posts', { id => route_parameters->get('id') });
    send_error('Post not found', 404) unless $post;
    
    template 'posts/editor', { post => $post, action => 'update' };
};

put '/admin/posts/:id' => sub {
    require_role('author');
    
    my $id = route_parameters->get('id');
    my $markdown = body_parameters->get('content_markdown') // '';
    my $html = markdown($markdown);
    
    database->quick_update('posts',
        { id => $id },
        {
            title            => body_parameters->get('title'),
            excerpt          => body_parameters->get('excerpt'),
            content_markdown => $markdown,
            content_html     => $html,
            published        => body_parameters->get('published') ? 1 : 0,
            updated_at       => \'NOW()',
        }
    );
    
    if (request->is_ajax) {
        return { success => 1 };
    }
    redirect '/admin/posts';
};

del '/admin/posts/:id' => sub {
    require_role('author');
    
    database->quick_delete('posts', { id => route_parameters->get('id') });
    
    if (request->is_ajax) {
        return { success => 1 };
    }
    redirect '/admin/posts';
};

# ═══════════════════════════════════════════════════════════════════════════════
# Pages CRUD
# ═══════════════════════════════════════════════════════════════════════════════

get '/admin/pages' => sub {
    require_role('editor');
    
    my @pages = database->quick_select_all('pages', {},
        { order_by => 'title' }
    );
    
    template 'pages/list', { pages => \@pages };
};

get '/admin/pages/new' => sub {
    require_role('editor');
    template 'pages/editor', { page => {}, action => 'create' };
};

post '/admin/pages' => sub {
    require_role('editor');
    
    my $markdown = body_parameters->get('content_markdown') // '';
    my $html = markdown($markdown);
    my $title = body_parameters->get('title') // 'Untitled';
    my $slug = body_parameters->get('slug') || _slugify($title);
    
    database->quick_insert('pages', {
        title            => $title,
        slug             => $slug,
        content_markdown => $markdown,
        content_html     => $html,
        published        => body_parameters->get('published') ? 1 : 0,
        created_at       => \'NOW()',
        updated_at       => \'NOW()',
    });
    
    if (request->is_ajax) {
        return { success => 1, slug => $slug };
    }
    redirect '/admin/pages';
};

get '/admin/pages/:id/edit' => sub {
    require_role('editor');
    
    my $page = database->quick_select('pages', { id => route_parameters->get('id') });
    send_error('Page not found', 404) unless $page;
    
    template 'pages/editor', { page => $page, action => 'update' };
};

put '/admin/pages/:id' => sub {
    require_role('editor');
    
    my $id = route_parameters->get('id');
    my $markdown = body_parameters->get('content_markdown') // '';
    my $html = markdown($markdown);
    
    database->quick_update('pages',
        { id => $id },
        {
            title            => body_parameters->get('title'),
            slug             => body_parameters->get('slug'),
            content_markdown => $markdown,
            content_html     => $html,
            published        => body_parameters->get('published') ? 1 : 0,
            updated_at       => \'NOW()',
        }
    );
    
    if (request->is_ajax) {
        return { success => 1 };
    }
    redirect '/admin/pages';
};

# ═══════════════════════════════════════════════════════════════════════════════
# API Endpoints (for AJAX/live preview)
# ═══════════════════════════════════════════════════════════════════════════════

prefix '/admin/api' => sub {
    
    # Live markdown preview
    post '/preview' => sub {
        require_login();
        
        my $markdown = body_parameters->get('markdown') // '';
        my $html = markdown($markdown);
        
        return { html => $html };
    };
    
    # Auto-save draft
    post '/drafts/:type/:id' => sub {
        require_login();
        
        my $type = route_parameters->get('type');
        my $id = route_parameters->get('id');
        my $content = body_parameters->get('content');
        
        # Store in session or temp table
        session("draft_${type}_${id}" => $content);
        
        return { success => 1, saved_at => time() };
    };
    
    # Get draft
    get '/drafts/:type/:id' => sub {
        require_login();
        
        my $type = route_parameters->get('type');
        my $id = route_parameters->get('id');
        
        my $content = session("draft_${type}_${id}");
        
        return { content => $content };
    };
    
    # Slug generator
    post '/slugify' => sub {
        my $title = body_parameters->get('title') // '';
        return { slug => _slugify($title) };
    };
};

# ═══════════════════════════════════════════════════════════════════════════════
# Media/Upload Management
# ═══════════════════════════════════════════════════════════════════════════════

get '/admin/media' => sub {
    require_role('author');
    
    my @media = database->quick_select_all('media', {},
        { order_by => { desc => 'created_at' } }
    );
    
    template 'media/list', { media => \@media };
};

post '/admin/media/upload' => sub {
    require_role('author');
    
    my $upload = request->upload('file');
    send_error('No file uploaded', 400) unless $upload;
    
    my $filename = $upload->filename;
    my $safe_name = _safe_filename($filename);
    my $upload_path = path(setting('uploads'), $safe_name);
    
    $upload->copy_to($upload_path);
    
    database->quick_insert('media', {
        filename     => $safe_name,
        original_name => $filename,
        mime_type    => $upload->type,
        size         => $upload->size,
        path         => "/uploads/$safe_name",
        created_at   => \'NOW()',
    });
    
    if (request->is_ajax) {
        return {
            success => 1,
            url => "/uploads/$safe_name",
            filename => $safe_name,
        };
    }
    redirect '/admin/media';
};

# ═══════════════════════════════════════════════════════════════════════════════
# User Management (Admin only)
# ═══════════════════════════════════════════════════════════════════════════════

get '/admin/users' => sub {
    require_role('admin');
    
    my @users = database->quick_select_all('users', {},
        { order_by => 'username' }
    );
    
    template 'users/list', { users => \@users };
};

post '/admin/users' => sub {
    require_role('admin');
    
    my $password = body_parameters->get('password');
    my $password_hash = sha256_hex($password);
    
    database->quick_insert('users', {
        username      => body_parameters->get('username'),
        email         => body_parameters->get('email'),
        password_hash => $password_hash,
        role          => body_parameters->get('role') // 'author',
        created_at    => \'NOW()',
    });
    
    redirect '/admin/users';
};

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

sub _slugify {
    my ($text) = @_;
    return '' unless defined $text;
    
    $text = lc($text);
    $text =~ s/[^\w\s-]//g;
    $text =~ s/[\s_]+/-/g;
    $text =~ s/^-+|-+$//g;
    
    return $text;
}

sub _safe_filename {
    my ($filename) = @_;
    
    my ($name, $ext) = $filename =~ /^(.+?)\.(\w+)$/;
    $name //= $filename;
    $ext //= 'bin';
    
    $name =~ s/[^\w.-]/_/g;
    $ext = lc($ext);
    
    my $timestamp = time();
    return "${name}_${timestamp}.${ext}";
}

true;

__END__

=head1 NAME

CMS::Backend - Dancer2 admin backend for OpenCy CMS

=head1 DESCRIPTION

Provides the admin interface for the CMS including:

=over

=item * User authentication and authorization

=item * Blog post management with Markdown editor

=item * Page management

=item * Media uploads

=item * Live preview API

=back

=head1 ROUTES

    GET  /admin              - Dashboard
    GET  /admin/login        - Login form
    POST /admin/login        - Process login
    GET  /admin/logout       - Logout
    
    GET  /admin/posts        - List posts
    GET  /admin/posts/new    - New post form
    POST /admin/posts        - Create post
    GET  /admin/posts/:id/edit - Edit post
    PUT  /admin/posts/:id    - Update post
    DEL  /admin/posts/:id    - Delete post
    
    GET  /admin/pages        - List pages
    ...similar CRUD routes...
    
    POST /admin/api/preview  - Markdown preview

=cut
