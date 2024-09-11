use strict;
use warnings;
use IO::Async::Loop;
use IO::Async::Listener;
use Future::Utils qw( try_repeat );
use HTTP::Date qw(time2str);
use File::MimeInfo;
use Fcntl qw(:mode);
use File::Spec;

our $document_root = 'host-site/';
our $loop = IO::Async::Loop->new;
our %status = (200 => "200: OK", 404 => "404: Not Found");

sub get_mime_type {
    my ($file) = @_;
    my $mime_type = mimetype($file) || 'application/octet-stream';
    return $mime_type;
}

sub requests {
    # will process the types of requests here
}



sub headers {
    # will parse the header here and construct header sent here
    my $full_path = $_[1];
    
    my @stat = stat($full_path);
    my $size = $stat[7];
    my $mtime = $stat[9];

    my $content_type = get_mime_type($full_path);

    my $header = "HTTP/1.1 $status{200} \r\n\r\n";
    my $server_name = "Server: perljam\r\n";
    my $modified = "Last-Modified: " . time2str($mtime) . "\r\n";
    my $type = "Content-Type: $content_type\r\n";
    my $content_len = "Content-Length: $size\r\n";
    
    my $response = $header . $server_name . $modified . $type . $content_len . "\r\n";
    return $response;
}

sub serve_file {
    my ($stream, $path) = @_;
    my $full_path = File::Spec->catfile($document_root, $path);
    $full_path =~ s/^\.\.//g;

    if (-f $full_path) {
        
        my $content;
        my $file_exists = 1;
        my $fh;

        unless (open $fh, '<:raw', $full_path) {
            $file_exists = 0;
        }
        # open my $fh, '<:raw', $full_path or die "Can't open $full_path: $!";
        if($file_exists) {
            $content = do { local $/; <$fh> };
        } else {

        }
        
        close $fh;

        # my $response = "HTTP/1.1 200 OK\r\n" .
        #                "Content-Type: $content_type\r\n" .
        #                "Content-Length: $size\r\n" .
        #                "Last-Modified: " . time2str($mtime) . "\r\n" .
        #                "\r\n" .
        #                $content;

        my $response = headers($full_path) . $content;

        $stream->write($response);
    } else {
        my $response = "HTTP/1.1 404 Not Found\r\n" .
                       "Content-Type: text/plain\r\n" .
                       "Content-Length: 9\r\n" .
                       "\r\n" .
                       "Not Found";
        $stream->write($response);
    }
}

my $listener = IO::Async::Listener->new(
    on_stream => sub {
        my ($self, $stream) = @_;

        $stream->configure(
            on_read => sub {
                my ($self, $buffref, $eof) = @_;

                while ($$buffref =~ s/^(.*\n)//) {
                    my $line = $1;
                    print "Received: $line";
                    $stream->write("You said: $line");
                }

                return 0;
            },
        );

        $loop->add($stream);
    },
);

$loop->add($listener);

my $server_future = $listener->listen(
    addr => {
        family   => 'inet',
        socktype => 'stream',
        port     => 8080,
    },
)->then(
    sub {
        my ($socket) = @_;
        print "Server running on port 8080\n";

        try_repeat {
            $listener->accept
        } while => sub { 1 };
    },
    sub {
        my ($error) = @_;
        die "Listen error: $error\n";
    }
);

$loop->run($server_future);
