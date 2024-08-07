# SUSE's openQA tests
#
# Copyright SUSE LLC
# SPDX-License-Identifier: FSFAP
# Maintainer: QE-SAP <qe-sap@suse.de>

# Summary: Triggers cleanup of the workload zone and SUT using SDAF automation.
# It also removes all SDAF test related files from deployer VM.
# Post run hooks are generally disabled during normal module run so the infrastructure persists between test modules.
# Cleanup is triggered only with B<SDAF_DO_CLEANUP> set to true, which is done by scheduling this module at the end of test flow.

use parent 'sles4sap::sap_deployment_automation_framework::basetest';
use strict;
use testapi;
use warnings;
use sles4sap::sap_deployment_automation_framework::deployment
  qw(serial_console_diag_banner
  sdaf_cleanup
  az_login
  load_os_env_variables);
use sles4sap::sap_deployment_automation_framework::deployment_connector qw(find_deployer_resources);
use sles4sap::console_redirection qw(connect_target_to_serial disconnect_target_from_serial);
use sles4sap::azure_cli qw(az_resource_delete);

sub test_flags {
    return {fatal => 1};
}

sub run {
    serial_console_diag_banner('Start: sdaf_cleanup.pm');
    if (get_var('SDAF_RETAIN_DEPLOYMENT')) {
        record_info('Cleanup OFF', 'OpenQA variable "SDAF_RETAIN_DEPLOYMENT" is active, skipping cleanup.');
        return;
    }

    # Trigger SDAF remover script to destroy 'workload zone' and 'sap systems' resources
    # Clean up all config files, keys, etc.. on deployer VM
    connect_target_to_serial();
    load_os_env_variables();
    az_login();
    sdaf_cleanup();
    disconnect_target_from_serial();

    # Cleanup deployer VM resources only
    # Deployer VM is located in permanent deployer resource group. This RG **MUST STAY INTACT**
    my @resource_cleanup_list = @{find_deployer_resources(return_value => 'id')};
    record_info('Resources destroy',
        "Following resources are being destroyed:\n" . join("\n", @{find_deployer_resources()}));

    az_resource_delete(ids => join(' ', @resource_cleanup_list),
        resource_group => get_required_var('SDAF_DEPLOYER_RESOURCE_GROUP'), timeout => '600');

    serial_console_diag_banner('End: sdaf_cleanup.pm');
}

1;
