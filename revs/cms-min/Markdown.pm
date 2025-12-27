package PerlJam::Markdown;
#
# PerlJam::Markdown - Basic Markdown to HTML converter
# Implements a useful subset of Markdown without external dependencies
#
# Supported syntax:
#   # Heading 1-6
#   **bold** or __bold__
#   *italic* or _italic_
#   `inline code`
#   ```code blocks```
#   [link](url) or [link](url "title")
#   ![alt](image)
#   > blockquotes
#   - unordered lists
#   1. ordered lists
#   --- or *** horizontal rules
#   Paragraphs (blank line separated)
#
use strict;
use warnings;
use v5.14;

use PerlJam::Util qw(html_escape);

use Exporter 'import';
our @EXPORT_OK = qw(markdown);

# Main conversion function
sub markdown {
    my ($text) = @_;
    return '' unless defined $text && $text =~ /\S/;
    
    # Normalize line endings
    $text =~ s/\r\n/\n/g;
    $text =~ s/\r/\n/g;
    
    # Protect code blocks first (they should not be processed)
    my @code_blocks;
    $text =~ s{^```(\w*)\n(.*?)^```}{ _save_code_block(\@code_blocks, $1, $2) }gmse;
    
    # Protect inline code
    my @inline_code;
    $text =~ s{`([^`]+)`}{ _save_inline_code(\@inline_code, $1) }ge;
    
    # Process block elements
    $text = _process_blocks($text);
    
    # Restore inline code
    $text =~ s/\x00IC(\d+)\x00/<code>$inline_code[$1]<\/code>/g;
    
    # Restore code blocks
    $text =~ s/\x00CB(\d+)\x00/$code_blocks[$1]/g;
    
    return $text;
}

sub _save_code_block {
    my ($blocks, $lang, $code) = @_;
    $code = html_escape($code);
    $code =~ s/\n$//;  # Remove trailing newline
    
    my $class = $lang ? qq{ class="language-$lang"} : '';
    push @$blocks, "<pre><code$class>$code</code></pre>";
    return "\x00CB" . $#{$blocks} . "\x00";
}

sub _save_inline_code {
    my ($codes, $code) = @_;
    push @$codes, html_escape($code);
    return "\x00IC" . $#{$codes} . "\x00";
}

sub _process_blocks {
    my ($text) = @_;
    
    my @blocks = split /\n{2,}/, $text;
    my @output;
    
    for my $block (@blocks) {
        next unless $block =~ /\S/;
        
        # Horizontal rule
        if ($block =~ /^(?:[-*_]\s*){3,}$/) {
            push @output, '<hr>';
            next;
        }
        
        # Headings
        if ($block =~ /^(#{1,6})\s+(.+)$/) {
            my $level = length($1);
            my $content = _process_inline($2);
            push @output, "<h$level>$content</h$level>";
            next;
        }
        
        # Blockquote
        if ($block =~ /^>\s/) {
            my @lines = map { s/^>\s?//; $_ } split /\n/, $block;
            my $content = _process_blocks(join("\n\n", @lines));
            push @output, "<blockquote>$content</blockquote>";
            next;
        }
        
        # Unordered list
        if ($block =~ /^[-*+]\s/) {
            push @output, _process_list($block, 'ul');
            next;
        }
        
        # Ordered list
        if ($block =~ /^\d+\.\s/) {
            push @output, _process_list($block, 'ol');
            next;
        }
        
        # Code block placeholder (already processed)
        if ($block =~ /^\x00CB\d+\x00$/) {
            push @output, $block;
            next;
        }
        
        # Default: paragraph
        my $content = _process_inline($block);
        $content =~ s/\n/<br>\n/g;  # Hard breaks
        push @output, "<p>$content</p>";
    }
    
    return join("\n", @output);
}

sub _process_list {
    my ($block, $type) = @_;
    
    my @items;
    my $current = '';
    
    for my $line (split /\n/, $block) {
        if ($line =~ /^(?:[-*+]|\d+\.)\s+(.*)/) {
            push @items, $current if $current;
            $current = $1;
        } else {
            # Continuation
            $line =~ s/^\s{2,}//;
            $current .= "\n" . $line;
        }
    }
    push @items, $current if $current;
    
    my $html = "<$type>\n";
    for my $item (@items) {
        my $content = _process_inline($item);
        $html .= "<li>$content</li>\n";
    }
    $html .= "</$type>";
    
    return $html;
}

sub _process_inline {
    my ($text) = @_;
    
    # Escape HTML first (but preserve our placeholders)
    $text =~ s/(?<!\x00)([<>&])/ $1 eq '<' ? '&lt;' : $1 eq '>' ? '&gt;' : '&amp;' /ge;
    
    # Images: ![alt](url) or ![alt](url "title")
    $text =~ s{!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)}{
        my $alt = $1;
        my $src = $2;
        my $title = $3 ? qq{ title="$3"} : '';
        qq{<img src="$src" alt="$alt"$title>}
    }ge;
    
    # Links: [text](url) or [text](url "title")
    $text =~ s{\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)}{
        my $label = $1;
        my $href = $2;
        my $title = $3 ? qq{ title="$3"} : '';
        qq{<a href="$href"$title>$label</a>}
    }ge;
    
    # Bold: **text** or __text__
    $text =~ s/\*\*(.+?)\*\*/<strong>$1<\/strong>/g;
    $text =~ s/__(.+?)__/<strong>$1<\/strong>/g;
    
    # Italic: *text* or _text_ (but not inside words for underscore)
    $text =~ s/\*([^*]+)\*/<em>$1<\/em>/g;
    $text =~ s/(?<![a-zA-Z0-9])_([^_]+)_(?![a-zA-Z0-9])/<em>$1<\/em>/g;
    
    # Strikethrough: ~~text~~
    $text =~ s/~~(.+?)~~/<del>$1<\/del>/g;
    
    return $text;
}

1;

__END__

=head1 NAME

PerlJam::Markdown - Basic Markdown to HTML converter

=head1 SYNOPSIS

    use PerlJam::Markdown qw(markdown);
    
    my $html = markdown($text);

=head1 SUPPORTED SYNTAX

    # Heading 1
    ## Heading 2
    
    **bold** or __bold__
    *italic* or _italic_
    ~~strikethrough~~
    
    `inline code`
    
    ```perl
    # code block
    print "hello";
    ```
    
    [Link text](https://example.com)
    [Link with title](https://example.com "Title")
    
    ![Alt text](image.png)
    
    > Blockquote
    
    - Unordered
    - List
    
    1. Ordered
    2. List
    
    ---  (horizontal rule)

=head1 LIMITATIONS

This is a minimal implementation. Not supported:

- Reference-style links
- Tables
- Nested lists (beyond 2 levels)
- Footnotes
- Definition lists
- Task lists

For full Markdown support, use Text::Markdown or Text::MultiMarkdown.

=cut
