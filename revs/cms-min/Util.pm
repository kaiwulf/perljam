package PerlJam::Util;
#
# PerlJam::Util - Pure Perl replacements for common dependencies
# No external CPAN modules required (uses only core Perl)
#
use strict;
use warnings;
use v5.14;  # for JSON::PP in core

use Exporter 'import';
our @EXPORT_OK = qw(
    uri_escape uri_unescape
    html_escape html_unescape
    http_date parse_http_date
    mime_type
    slug
    random_hex
    base64_encode base64_decode
);

#═══════════════════════════════════════════════════════════════════════════════
# URI Encoding/Decoding (replaces URI::Escape)
#═══════════════════════════════════════════════════════════════════════════════

sub uri_escape {
    my ($string) = @_;
    return '' unless defined $string;
    
    $string =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $string;
}

sub uri_unescape {
    my ($string) = @_;
    return '' unless defined $string;
    
    $string =~ s/\+/ /g;
    $string =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $string;
}

#═══════════════════════════════════════════════════════════════════════════════
# HTML Escaping (replaces HTML::Escape)
#═══════════════════════════════════════════════════════════════════════════════

my %html_escape = (
    '&' => '&amp;',
    '<' => '&lt;',
    '>' => '&gt;',
    '"' => '&quot;',
    "'" => '&#39;',
);

my %html_unescape = reverse %html_escape;
$html_unescape{'&#x27;'} = "'";
$html_unescape{'&apos;'} = "'";

sub html_escape {
    my ($string) = @_;
    return '' unless defined $string;
    
    $string =~ s/([&<>"'])/$html_escape{$1}/ge;
    return $string;
}

sub html_unescape {
    my ($string) = @_;
    return '' unless defined $string;
    
    $string =~ s/(&(?:amp|lt|gt|quot|#39|#x27|apos);)/$html_unescape{$1} \/\/ $1/ge;
    return $string;
}

#═══════════════════════════════════════════════════════════════════════════════
# HTTP Date Formatting (replaces HTTP::Date)
#═══════════════════════════════════════════════════════════════════════════════

my @WDAY = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MON  = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

sub http_date {
    my ($time) = @_;
    $time //= time();
    
    my @t = gmtime($time);
    return sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT",
        $WDAY[$t[6]],
        $t[3],
        $MON[$t[4]],
        $t[5] + 1900,
        $t[2], $t[1], $t[0]
    );
}

my %MON_NUM = map { $MON[$_] => $_ } 0..11;

sub parse_http_date {
    my ($string) = @_;
    return unless defined $string;
    
    # RFC 7231 format: Sun, 06 Nov 1994 08:49:37 GMT
    if ($string =~ /^\w+,\s+(\d{2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$/) {
        my ($day, $mon, $year, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
        my $mon_num = $MON_NUM{$mon};
        return unless defined $mon_num;
        
        require Time::Local;
        return eval { Time::Local::timegm($sec, $min, $hour, $day, $mon_num, $year - 1900) };
    }
    
    return;
}

#═══════════════════════════════════════════════════════════════════════════════
# MIME Type Detection (replaces File::MimeInfo)
#═══════════════════════════════════════════════════════════════════════════════

my %MIME_TYPES = (
    # Text
    html  => 'text/html',
    htm   => 'text/html',
    css   => 'text/css',
    js    => 'text/javascript',
    mjs   => 'text/javascript',
    json  => 'application/json',
    xml   => 'application/xml',
    txt   => 'text/plain',
    md    => 'text/markdown',
    csv   => 'text/csv',
    
    # Images
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    webp  => 'image/webp',
    svg   => 'image/svg+xml',
    ico   => 'image/x-icon',
    bmp   => 'image/bmp',
    
    # Fonts
    woff  => 'font/woff',
    woff2 => 'font/woff2',
    ttf   => 'font/ttf',
    otf   => 'font/otf',
    eot   => 'application/vnd.ms-fontobject',
    
    # Audio/Video
    mp3   => 'audio/mpeg',
    wav   => 'audio/wav',
    ogg   => 'audio/ogg',
    mp4   => 'video/mp4',
    webm  => 'video/webm',
    
    # Documents
    pdf   => 'application/pdf',
    doc   => 'application/msword',
    docx  => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xls   => 'application/vnd.ms-excel',
    xlsx  => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ppt   => 'application/vnd.ms-powerpoint',
    pptx  => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    
    # Archives
    zip   => 'application/zip',
    gz    => 'application/gzip',
    tar   => 'application/x-tar',
    rar   => 'application/vnd.rar',
    '7z'  => 'application/x-7z-compressed',
    
    # Code
    pl    => 'text/x-perl',
    pm    => 'text/x-perl',
    raku  => 'text/x-raku',
    py    => 'text/x-python',
    rb    => 'text/x-ruby',
    c     => 'text/x-c',
    h     => 'text/x-c',
    cpp   => 'text/x-c++',
    java  => 'text/x-java',
    sh    => 'text/x-shellscript',
    
    # Data
    sql   => 'application/sql',
    yaml  => 'text/yaml',
    yml   => 'text/yaml',
    toml  => 'text/toml',
);

sub mime_type {
    my ($filename) = @_;
    return 'application/octet-stream' unless defined $filename;
    
    my ($ext) = $filename =~ /\.(\w+)$/;
    return 'application/octet-stream' unless defined $ext;
    
    return $MIME_TYPES{lc $ext} // 'application/octet-stream';
}

#═══════════════════════════════════════════════════════════════════════════════
# Slug Generation
#═══════════════════════════════════════════════════════════════════════════════

sub slug {
    my ($text) = @_;
    return '' unless defined $text;
    
    $text = lc($text);
    $text =~ s/[^\w\s-]//g;      # Remove non-word chars
    $text =~ s/[\s_]+/-/g;       # Spaces/underscores to hyphens
    $text =~ s/^-+|-+$//g;       # Trim leading/trailing hyphens
    
    return $text;
}

#═══════════════════════════════════════════════════════════════════════════════
# Random Hex String (for tokens, filenames, etc.)
#═══════════════════════════════════════════════════════════════════════════════

sub random_hex {
    my ($length) = @_;
    $length //= 32;
    
    my $hex = '';
    for (1 .. $length) {
        $hex .= sprintf("%x", int(rand(16)));
    }
    return $hex;
}

#═══════════════════════════════════════════════════════════════════════════════
# Base64 (using core MIME::Base64, but providing wrapper)
#═══════════════════════════════════════════════════════════════════════════════

# These are actually core, but providing pure-perl fallback
sub base64_encode {
    my ($data) = @_;
    
    # Try core module first
    if (eval { require MIME::Base64; 1 }) {
        return MIME::Base64::encode_base64($data, '');
    }
    
    # Pure Perl fallback
    my $b64 = '';
    my @chars = ('A'..'Z', 'a'..'z', '0'..'9', '+', '/');
    
    while (length($data) >= 3) {
        my $chunk = substr($data, 0, 3, '');
        my $n = unpack('N', "\0" . $chunk);
        $b64 .= $chars[($n >> 18) & 0x3f];
        $b64 .= $chars[($n >> 12) & 0x3f];
        $b64 .= $chars[($n >> 6) & 0x3f];
        $b64 .= $chars[$n & 0x3f];
    }
    
    if (length($data) == 2) {
        my $n = unpack('N', "\0\0" . $data);
        $b64 .= $chars[($n >> 10) & 0x3f];
        $b64 .= $chars[($n >> 4) & 0x3f];
        $b64 .= $chars[($n << 2) & 0x3f];
        $b64 .= '=';
    } elsif (length($data) == 1) {
        my $n = ord($data);
        $b64 .= $chars[$n >> 2];
        $b64 .= $chars[($n << 4) & 0x3f];
        $b64 .= '==';
    }
    
    return $b64;
}

sub base64_decode {
    my ($b64) = @_;
    
    if (eval { require MIME::Base64; 1 }) {
        return MIME::Base64::decode_base64($b64);
    }
    
    # Pure Perl fallback
    my %val;
    my @chars = ('A'..'Z', 'a'..'z', '0'..'9', '+', '/');
    $val{$chars[$_]} = $_ for 0..63;
    
    $b64 =~ s/[^A-Za-z0-9+\/=]//g;
    my $pad = ($b64 =~ s/=+$//);
    
    my $data = '';
    while (length($b64) >= 4) {
        my @c = map { $val{$_} // 0 } split //, substr($b64, 0, 4, '');
        my $n = ($c[0] << 18) | ($c[1] << 12) | ($c[2] << 6) | $c[3];
        $data .= chr(($n >> 16) & 0xff);
        $data .= chr(($n >> 8) & 0xff);
        $data .= chr($n & 0xff);
    }
    
    # Remove padding bytes
    $data = substr($data, 0, -$pad) if $pad;
    
    return $data;
}

1;

__END__

=head1 NAME

PerlJam::Util - Pure Perl utility functions

=head1 SYNOPSIS

    use PerlJam::Util qw(uri_escape html_escape http_date mime_type);
    
    my $encoded = uri_escape("hello world");  # hello%20world
    my $safe = html_escape("<script>");       # &lt;script&gt;
    my $date = http_date();                   # Sun, 27 Dec 2025 12:00:00 GMT
    my $type = mime_type("style.css");        # text/css

=head1 DESCRIPTION

Drop-in replacements for common CPAN modules using only core Perl.
Replaces: URI::Escape, HTML::Escape, HTTP::Date, File::MimeInfo

=cut
