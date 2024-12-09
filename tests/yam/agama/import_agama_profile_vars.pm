## Copyright 2024 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# Summary: Run Agama profile import on Live Medium with vars in profile
# Maintainer: QE YaST and Migration (QE Yam) <qe-yam at suse de>

use base Yam::Agama::patch_agama_base;
use strict;
use warnings;
use testapi;
use autoyast qw(expand_variables);

sub run {
    select_console 'root-console';
    my $profile = get_required_var('AGAMA_PROFILE');

    my $content = expand_variables(get_test_data($profile));
    my $profile_expanded = 'profile.json';
    save_tmp_file($profile_expanded, $content);
    my $profile_url = autoinst_url . "/files/$profile_expanded";
    script_run("cat $profile_url");
    
    script_run("dmesg --console-off");
    assert_script_run("/usr/bin/agama profile import $profile_url", timeout => 300);
    script_run("dmesg --console-on");
}

1;
