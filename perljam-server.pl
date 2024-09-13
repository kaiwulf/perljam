use strict;
use warnings;
use IO::Async::Loop;
use IO::Async::Listener;
use Future::Utils qw( try_repeat );
use HTTP::Date qw(time2str);
use File::MimeInfo;
use Fcntl qw(:mode);
use File::Spec;
use Cwd 'abs_path';

our $document_root = 'host-site/www/';
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

sub debug_print {
    my ($message) = @_;
    print "$message\n";
}

sub headers {
    # will parse the header here and construct header sent here
    my $status_code = $_[0];
    my $full_path = $_[1];
    
    my @stat = stat($full_path);
    my $size = $stat[7];
    my $mtime = $stat[9];

    my $content_type = get_mime_type($full_path);

    # my $modified = "Last-Modified: " . time2str($mtime) . "\r\n";

    my $header = "HTTP/1.1 $status{$status_code} \r\n";
    my $server_name = "Server: perljam/0.0.1 alpha\r\n";
    my $date = "Date: ". time2str($mtime) . "\r\n";
    my $cache_control = "Cache-Control: no-cache, must-revalidate\r\n";
    my $expire = "Expires: Sat, 26 Jul 1997 05:00:00 GMT\r\n";
    my $x_frame = "X-Frame-Options: DENY\r\n";
    my $xxss_protect = "X-XSS-Protection: 1; mode=block\r\n";
    my $strict_transport = "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n";
    my $type = "Content-Type: $content_type\r\n";
    my $content_len = "Content-Length: $size\r\n";
    my $connection = "Connection: keep-alive\r\n";
    my $blank = "\r\n";
    
    my $response = $header . $server_name . $date . $cache_control . $expire . $x_frame . $xxss_protect . $strict_transport . $type . $content_len . $connection . $blank;
    return $response;
}

sub serve_file {
    my ($stream, $path, $cmd) = @_;
    $path =~ s/^\/+//;
    my $full_path = File::Spec->catfile($document_root, $path);
    # $full_path =~ s/^\.\.//g;
    my $real_path = abs_path($full_path);
    print "real path $real_path\n\n";

    if (-e $real_path) {
        
        my $content;
        open my $fh, '<:raw', $full_path or die "Can't open $full_path: $!";
        $content = do { local $/; <$fh> };
        close $fh;

        # my $
        my $response = headers(200, $full_path) . $content;
        print "sending response:\n$response\n";
        $stream->write($response);
    } else {
        my $response = headers(404, '') . "Not Found";
        print "sending response:\n$response\n";
        $stream->write($response);
    }
}

eval {
    my $listener = IO::Async::Listener->new(
        on_stream => sub {
            my ($self, $stream) = @_;
            print "New connection received from " . $stream->read_handle->peerhost . "\n\n";

            $stream->configure(
                on_read => sub {
                    my ($self, $buffref, $eof) = @_;

                    print "Received data: $$buffref\n\n";

                    # while ($$buffref =~ s/^GET (\/\S*) HTTP\/1\.[01]\r\n.*\r\n\r\n//s) {
                    while ($$buffref =~ s/([A-Z]+) (\/\S*) HTTP\/1\.[01]\r\n.*\r\n\r\n//s) {
                        my $cmd = $1;
                        my $path = $2;
                        $path = '/' if $path eq '';
                        print "Serving file: $path\n\n";
                        serve_file($stream, $path, $cmd);
                        return 1;
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
            port     => 8081,
        },
    )->get;
    $loop->run;
};

if ($@) {
    debug_print("An error occurred: $@");
}

debug_print("Script execution completed.");