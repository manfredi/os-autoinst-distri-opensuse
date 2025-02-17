# SUSE's openQA tests
#
# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Validate that the hostname is set properly by Agama.
# Check if hostname matches the one defined on EXPECTED_INSTALL_HOSTNAME or is "localhost"

# Maintainer: QE YaST and Migration (QE Yam) <qe-yam at suse de>

use base "consoletest";
use strict;
use warnings;
use testapi;
use Test::Assert ':assert';

sub run {
    select_console 'root-console';
    my $expected_install_hostname = get_var('EXPECTED_INSTALL_HOSTNAME') // 'localhost';
    my $hostname = script_output('hostname -s');
    assert_str_equals($expected_install_hostname, $hostname, "Wrong hostname. Expected: '$expected_install_hostname', got '$hostname'");
}

1;
