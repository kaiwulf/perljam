#!/usr/bin/env perl
#
# OpenCy CMS Backend - Dancer2 Application
#
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

use Dancer2;
use CMS::Backend;

# Configuration
set port     => $ENV{DANCER_PORT} // 5000;
set host     => $ENV{DANCER_HOST} // '0.0.0.0';
set startup_info => 1;
set show_errors  => 1;

# Database configuration
set plugins => {
    Database => {
        driver   => 'SQLite',
        database => $ENV{CMS_DATABASE} // "$FindBin::Bin/../../shared/cms.db",
    },
};

# Template configuration
set template => 'template_toolkit';
set engines => {
    template => {
        template_toolkit => {
            start_tag => '<%',
            end_tag   => '%>',
            WRAPPER   => 'layouts/admin.tt',
        },
    },
};

# Session
set session => 'Simple';

# Paths
set public_dir  => "$FindBin::Bin/../public";
set views       => "$FindBin::Bin/../views";

# Start
dance;
