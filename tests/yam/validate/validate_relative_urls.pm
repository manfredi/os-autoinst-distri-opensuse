# SUSE's openQA tests
#
# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Validate relative URLs.
# Check the support of relative URLs, based on the URL of the profile.

# Maintainer: QE YaST and Migration (QE Yam) <qe-yam at suse de>

use base "consoletest";
use strict;
use warnings;
use testapi;

sub run {
    select_console 'root-console';
    # see section "download_file" in data/yam/agama/auto/lib/scripts_pre.libsonnet
    my %files = (
        '/usr/local/share/dummy.xml' => {
            mode => '644',
            owner => 'root',
            sha256sum => '5f925f748a27b757853767477ec0e0e6f04b1727f3607c7f622a2a1e4bd2a0e5'
        }
    );

    for my $file (keys %files) {
        assert_script_run("cat $file"); # debug
        validate_script_output(qq|stat -c "%a %U %n" $file|, qr/$files{$file}->{mode} $files{$file}->{owner} $file/);
        validate_script_output(qq|sha256sum $file|, qr/$files{$file}->{sha256sum}\s+$file/);
    }
}

1;
