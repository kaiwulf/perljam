package PerlJam::DB;
#
# PerlJam::DB - Minimal SQLite database access
# Uses sqlite3 CLI tool - no DBI/DBD::SQLite required
# Falls back to DBI if available for better performance
#
use strict;
use warnings;
use v5.14;

use JSON::PP;
use Carp qw(croak);

my $json = JSON::PP->new->utf8;

sub new {
    my ($class, $db_file) = @_;
    
    croak "Database file required" unless $db_file;
    
    my $self = bless {
        db_file  => $db_file,
        use_dbi  => 0,
        dbh      => undef,
    }, $class;
    
    # Try DBI first (faster)
    if (eval { require DBI; require DBD::SQLite; 1 }) {
        $self->{dbh} = DBI->connect("dbi:SQLite:dbname=$db_file", '', '', {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            sqlite_unicode => 1,
        });
        $self->{use_dbi} = 1;
    } else {
        # Check sqlite3 is available
        my $version = `sqlite3 --version 2>&1`;
        croak "sqlite3 not found and DBI not available" unless $version =~ /\d+\.\d+/;
    }
    
    return $self;
}

#═══════════════════════════════════════════════════════════════════════════════
# Query Methods
#═══════════════════════════════════════════════════════════════════════════════

sub query {
    my ($self, $sql, @params) = @_;
    
    if ($self->{use_dbi}) {
        return $self->_query_dbi($sql, @params);
    } else {
        return $self->_query_cli($sql, @params);
    }
}

sub _query_dbi {
    my ($self, $sql, @params) = @_;
    
    my $sth = $self->{dbh}->prepare($sql);
    $sth->execute(@params);
    
    # For SELECT, return rows
    if ($sql =~ /^\s*SELECT/i) {
        my @rows;
        while (my $row = $sth->fetchrow_hashref) {
            push @rows, $row;
        }
        return \@rows;
    }
    
    # For INSERT, return last insert id
    if ($sql =~ /^\s*INSERT/i) {
        return $self->{dbh}->last_insert_id('', '', '', '');
    }
    
    # For UPDATE/DELETE, return rows affected
    return $sth->rows;
}

sub _query_cli {
    my ($self, $sql, @params) = @_;
    
    # Escape parameters
    for my $i (0 .. $#params) {
        my $val = $params[$i];
        if (!defined $val) {
            $sql =~ s/\?/NULL/;
        } elsif ($val =~ /^-?\d+(?:\.\d+)?$/) {
            $sql =~ s/\?/$val/;
        } else {
            $val =~ s/'/''/g;  # Escape quotes
            $sql =~ s/\?/'$val'/;
        }
    }
    
    my $db = $self->{db_file};
    
    # For SELECT, use JSON output
    if ($sql =~ /^\s*SELECT/i) {
        my $result = `sqlite3 -json '$db' '$sql' 2>&1`;
        
        if ($? != 0) {
            croak "SQLite error: $result";
        }
        
        return [] if $result eq '' || $result eq '[]\n';
        
        my $data = eval { $json->decode($result) };
        return $data // [];
    }
    
    # For other statements
    my $result = `sqlite3 '$db' '$sql' 2>&1`;
    if ($? != 0) {
        croak "SQLite error: $result";
    }
    
    # For INSERT, get last rowid
    if ($sql =~ /^\s*INSERT/i) {
        my $id = `sqlite3 '$db' 'SELECT last_insert_rowid()'`;
        chomp $id;
        return $id;
    }
    
    # For UPDATE/DELETE, get changes
    my $changes = `sqlite3 '$db' 'SELECT changes()'`;
    chomp $changes;
    return $changes;
}

#═══════════════════════════════════════════════════════════════════════════════
# Convenience Methods
#═══════════════════════════════════════════════════════════════════════════════

sub select_one {
    my ($self, $table, $where) = @_;
    
    my ($sql, @params) = $self->_build_select($table, $where);
    $sql .= ' LIMIT 1';
    
    my $rows = $self->query($sql, @params);
    return $rows->[0];
}

sub select_all {
    my ($self, $table, $where, $options) = @_;
    
    my ($sql, @params) = $self->_build_select($table, $where);
    
    if (my $order = $options->{order_by}) {
        if (ref $order eq 'HASH') {
            my ($dir, $col) = each %$order;
            $sql .= " ORDER BY $col " . uc($dir);
        } else {
            $sql .= " ORDER BY $order";
        }
    }
    
    if (my $limit = $options->{limit}) {
        $sql .= " LIMIT $limit";
    }
    
    return $self->query($sql, @params);
}

sub insert {
    my ($self, $table, $data) = @_;
    
    my @cols = keys %$data;
    my @vals = @{$data}{@cols};
    my $placeholders = join ', ', ('?') x @cols;
    my $columns = join ', ', @cols;
    
    my $sql = "INSERT INTO $table ($columns) VALUES ($placeholders)";
    return $self->query($sql, @vals);
}

sub update {
    my ($self, $table, $where, $data) = @_;
    
    my @set_cols = keys %$data;
    my @set_vals = @{$data}{@set_cols};
    my $set_clause = join ', ', map { "$_ = ?" } @set_cols;
    
    my ($where_clause, @where_vals) = $self->_build_where($where);
    
    my $sql = "UPDATE $table SET $set_clause";
    $sql .= " WHERE $where_clause" if $where_clause;
    
    return $self->query($sql, @set_vals, @where_vals);
}

sub delete {
    my ($self, $table, $where) = @_;
    
    my ($where_clause, @where_vals) = $self->_build_where($where);
    
    my $sql = "DELETE FROM $table";
    $sql .= " WHERE $where_clause" if $where_clause;
    
    return $self->query($sql, @where_vals);
}

sub _build_select {
    my ($self, $table, $where) = @_;
    
    my $sql = "SELECT * FROM $table";
    my @params;
    
    if ($where && %$where) {
        my ($where_clause, @vals) = $self->_build_where($where);
        $sql .= " WHERE $where_clause";
        @params = @vals;
    }
    
    return ($sql, @params);
}

sub _build_where {
    my ($self, $where) = @_;
    
    return ('', ()) unless $where && %$where;
    
    my @clauses;
    my @vals;
    
    for my $col (keys %$where) {
        my $val = $where->{$col};
        
        if (!defined $val) {
            push @clauses, "$col IS NULL";
        } elsif (ref $val eq 'ARRAY') {
            my $placeholders = join ', ', ('?') x @$val;
            push @clauses, "$col IN ($placeholders)";
            push @vals, @$val;
        } elsif (ref $val eq 'SCALAR') {
            # Raw SQL: { col => \'NOW()' }
            push @clauses, "$col = $$val";
        } else {
            push @clauses, "$col = ?";
            push @vals, $val;
        }
    }
    
    return (join(' AND ', @clauses), @vals);
}

#═══════════════════════════════════════════════════════════════════════════════
# Schema & Transactions
#═══════════════════════════════════════════════════════════════════════════════

sub execute_file {
    my ($self, $file) = @_;
    
    if ($self->{use_dbi}) {
        open my $fh, '<', $file or croak "Cannot read $file: $!";
        local $/;
        my $sql = <$fh>;
        close $fh;
        
        for my $stmt (split /;/, $sql) {
            next unless $stmt =~ /\S/;
            $self->{dbh}->do($stmt);
        }
    } else {
        my $db = $self->{db_file};
        system("sqlite3 '$db' < '$file'") == 0
            or croak "Failed to execute $file";
    }
}

sub begin {
    my ($self) = @_;
    $self->query('BEGIN TRANSACTION');
}

sub commit {
    my ($self) = @_;
    $self->query('COMMIT');
}

sub rollback {
    my ($self) = @_;
    $self->query('ROLLBACK');
}

sub transaction {
    my ($self, $callback) = @_;
    
    $self->begin;
    eval {
        $callback->($self);
        $self->commit;
    };
    if ($@) {
        $self->rollback;
        croak $@;
    }
}

1;

__END__

=head1 NAME

PerlJam::DB - Minimal SQLite database access

=head1 SYNOPSIS

    my $db = PerlJam::DB->new('cms.db');
    
    # Raw query
    my $users = $db->query('SELECT * FROM users WHERE role = ?', 'admin');
    
    # Convenience methods
    my $user = $db->select_one('users', { id => 1 });
    my $posts = $db->select_all('posts', { published => 1 }, { order_by => 'created_at', limit => 10 });
    
    my $id = $db->insert('posts', { title => 'Hello', content => 'World' });
    $db->update('posts', { id => $id }, { title => 'Updated' });
    $db->delete('posts', { id => $id });
    
    # Transactions
    $db->transaction(sub {
        my ($db) = @_;
        $db->insert(...);
        $db->update(...);
    });

=head1 DESCRIPTION

Uses DBI/DBD::SQLite if available, falls back to sqlite3 CLI tool.
This allows running without any CPAN database modules installed.

=cut
