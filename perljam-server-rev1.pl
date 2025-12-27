#!/usr/bin/env perl
#
# perljam-server.pl - Minimal HTTP server for OpenCy CMS
# Uses only core Perl modules (5.14+)
#
use strict;
use warnings;
use v5.14;

use FindBin;
use lib "$FindBin::Bin/lib";

use PerlJam::Server;
use PerlJam::Util qw(html_escape slug);
use PerlJam::Markdown qw(markdown);
use PerlJam::Template;
use PerlJam::DB;

#═══════════════════════════════════════════════════════════════════════════════
# Configuration
#═══════════════════════════════════════════════════════════════════════════════

my %config = (
    port          => $ENV{PERLJAM_PORT}    // 8081,
    host          => $ENV{PERLJAM_HOST}    // '0.0.0.0',
    document_root => $ENV{PERLJAM_DOCROOT} // 'public',
    database      => $ENV{PERLJAM_DB}      // 'cms.db',
    upload_dir    => $ENV{PERLJAM_UPLOADS} // 'uploads',
    views         => $ENV{PERLJAM_VIEWS}   // 'views',
);

#═══════════════════════════════════════════════════════════════════════════════
# Initialize Components
#═══════════════════════════════════════════════════════════════════════════════

my $db = PerlJam::DB->new($config{database});

my $template = PerlJam::Template->new(
    path => [$config{views}, "$config{views}/layouts"],
);

my $server = PerlJam::Server->new(
    port          => $config{port},
    host          => $config{host},
    document_root => $config{document_root},
);

#═══════════════════════════════════════════════════════════════════════════════
# Session Helper (simple cookie-based)
#═══════════════════════════════════════════════════════════════════════════════

my %sessions;  # In-memory session store (use file/DB in production)

sub get_session {
    my ($req) = @_;
    my $cookie = $req->header('cookie') // '';
    my ($sid) = $cookie =~ /session=(\w+)/;
    return $sessions{$sid} if $sid && $sessions{$sid};
    return {};
}

sub set_session {
    my ($res, $data) = @_;
    my $sid = PerlJam::Util::random_hex(32);
    $sessions{$sid} = $data;
    $res->header('Set-Cookie', "session=$sid; Path=/; HttpOnly");
    return $sid;
}

#═══════════════════════════════════════════════════════════════════════════════
# Middleware
#═══════════════════════════════════════════════════════════════════════════════

$server->use(sub {
    my ($req, $res) = @_;
    
    # Add session to request
    $req->{session} = get_session($req);
    
    return 1;  # Continue
});

#═══════════════════════════════════════════════════════════════════════════════
# Public Routes
#═══════════════════════════════════════════════════════════════════════════════

$server->get('/' => sub {
    my ($req, $res) = @_;
    
    my $posts = $db->select_all('posts', 
        { published => 1 },
        { order_by => { desc => 'published_at' }, limit => 10 }
    );
    
    $res->html($template->render('home.tt', {
        title => 'Home',
        posts => $posts,
    }));
});

$server->get('/blog' => sub {
    my ($req, $res) = @_;
    
    my $posts = $db->select_all('posts',
        { published => 1 },
        { order_by => { desc => 'published_at' } }
    );
    
    $res->html($template->render('blog/index.tt', {
        title => 'Blog',
        posts => $posts,
    }));
});

$server->get('/blog/:slug' => sub {
    my ($req, $res) = @_;
    
    my $post = $db->select_one('posts', {
        slug      => $req->param('slug'),
        published => 1,
    });
    
    unless ($post) {
        return $res->error(404, 'Post not found');
    }
    
    $res->html($template->render('blog/post.tt', {
        title => $post->{title},
        post  => $post,
    }));
});

$server->get('/page/:slug' => sub {
    my ($req, $res) = @_;
    
    my $page = $db->select_one('pages', {
        slug      => $req->param('slug'),
        published => 1,
    });
    
    unless ($page) {
        return $res->error(404, 'Page not found');
    }
    
    $res->html($template->render('page.tt', {
        title => $page->{title},
        page  => $page,
    }));
});

#═══════════════════════════════════════════════════════════════════════════════
# API Routes
#═══════════════════════════════════════════════════════════════════════════════

$server->get('/api/health' => sub {
    my ($req, $res) = @_;
    $res->json({
        status => 'ok',
        server => 'perljam',
        uptime => time() - $^T,
    });
});

$server->post('/api/preview' => sub {
    my ($req, $res) = @_;
    
    my $md = $req->param('markdown') // '';
    my $html = markdown($md);
    
    $res->json({ html => $html });
});

$server->post('/api/upload' => sub {
    my ($req, $res) = @_;
    
    my @results;
    for my $file (@{$req->files}) {
        my $safe_name = _safe_filename($file->{filename});
        my $path = "$config{upload_dir}/$safe_name";
        
        mkdir $config{upload_dir} unless -d $config{upload_dir};
        
        open my $fh, '>:raw', $path or next;
        print $fh $file->{content};
        close $fh;
        
        push @results, {
            url      => "/uploads/$safe_name",
            filename => $safe_name,
            size     => $file->{size},
        };
    }
    
    $res->json({ success => 1, files => \@results });
});

#═══════════════════════════════════════════════════════════════════════════════
# Admin Routes
#═══════════════════════════════════════════════════════════════════════════════

sub require_login {
    my ($req, $res) = @_;
    unless ($req->{session}{user_id}) {
        $res->redirect('/admin/login');
        return 0;
    }
    return 1;
}

$server->get('/admin/login' => sub {
    my ($req, $res) = @_;
    $res->html($template->render('admin/login.tt', {}));
});

$server->post('/admin/login' => sub {
    my ($req, $res) = @_;
    
    my $username = $req->param('username');
    my $password = $req->param('password');
    
    # Simple password check (use proper hashing in production!)
    require Digest::SHA;
    my $hash = Digest::SHA::sha256_hex($password);
    
    my $user = $db->select_one('users', { username => $username });
    
    if ($user && $user->{password_hash} eq $hash) {
        set_session($res, {
            user_id  => $user->{id},
            username => $user->{username},
            role     => $user->{role},
        });
        $res->redirect('/admin');
    } else {
        $res->html($template->render('admin/login.tt', {
            error => 'Invalid username or password',
        }));
    }
});

$server->get('/admin' => sub {
    my ($req, $res) = @_;
    return unless require_login($req, $res);
    
    my $posts = $db->select_all('posts', {}, { order_by => { desc => 'updated_at' }, limit => 10 });
    my $pages = $db->select_all('pages', {}, { order_by => { desc => 'updated_at' }, limit => 10 });
    
    $res->html($template->render('admin/dashboard.tt', {
        user  => $req->{session},
        posts => $posts,
        pages => $pages,
    }));
});

$server->get('/admin/posts' => sub {
    my ($req, $res) = @_;
    return unless require_login($req, $res);
    
    my $posts = $db->select_all('posts', {}, { order_by => { desc => 'updated_at' } });
    
    $res->html($template->render('admin/posts/list.tt', {
        user  => $req->{session},
        posts => $posts,
    }));
});

$server->get('/admin/posts/new' => sub {
    my ($req, $res) = @_;
    return unless require_login($req, $res);
    
    $res->html($template->render('admin/posts/editor.tt', {
        user   => $req->{session},
        post   => {},
        action => 'create',
    }));
});

$server->post('/admin/posts' => sub {
    my ($req, $res) = @_;
    return unless require_login($req, $res);
    
    my $title = $req->param('title') // 'Untitled';
    my $md = $req->param('content_markdown') // '';
    
    my $id = $db->insert('posts', {
        title            => $title,
        slug             => slug($title),
        excerpt          => $req->param('excerpt'),
        content_markdown => $md,
        content_html     => markdown($md),
        author_id        => $req->{session}{user_id},
        published        => $req->param('published') ? 1 : 0,
    });
    
    $res->redirect('/admin/posts');
});

$server->get('/admin/posts/:id/edit' => sub {
    my ($req, $res) = @_;
    return unless require_login($req, $res);
    
    my $post = $db->select_one('posts', { id => $req->param('id') });
    
    unless ($post) {
        return $res->error(404, 'Post not found');
    }
    
    $res->html($template->render('admin/posts/editor.tt', {
        user   => $req->{session},
        post   => $post,
        action => 'update',
    }));
});

$server->post('/admin/posts/:id' => sub {
    my ($req, $res) = @_;
    return unless require_login($req, $res);
    
    my $md = $req->param('content_markdown') // '';
    
    $db->update('posts', 
        { id => $req->param('id') },
        {
            title            => $req->param('title'),
            excerpt          => $req->param('excerpt'),
            content_markdown => $md,
            content_html     => markdown($md),
            published        => $req->param('published') ? 1 : 0,
        }
    );
    
    $res->redirect('/admin/posts');
});

#═══════════════════════════════════════════════════════════════════════════════
# Helpers
#═══════════════════════════════════════════════════════════════════════════════

sub _safe_filename {
    my ($filename) = @_;
    my ($name, $ext) = $filename =~ /^(.+?)\.(\w+)$/;
    $name //= $filename;
    $ext //= 'bin';
    $name =~ s/[^\w.-]/_/g;
    return $name . '_' . time() . '.' . lc($ext);
}

#═══════════════════════════════════════════════════════════════════════════════
# Start Server
#═══════════════════════════════════════════════════════════════════════════════

say "╔══════════════════════════════════════════════════════════════╗";
say "║  OpenCy CMS - Minimal Edition                                ║";
say "║  Using only core Perl modules                                ║";
say "╚══════════════════════════════════════════════════════════════╝";

$server->run;
