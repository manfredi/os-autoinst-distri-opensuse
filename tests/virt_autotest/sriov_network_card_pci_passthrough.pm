# SUSE's openQA tests

# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Summary: A test to pass SR-IOV Ethernet VFs to guest via libvirt. Both KVM & XEN hosts are supported.
# Test environment: one or more Ethernet card with SR-IOV features in host machine as a secondary network card;
#                   hvm or pv domains defined in the host, and they are ssh accessible from host.
# Test flow:
#    - search the SR-IOV Ethernet cards installed in host.
#    - enable 7 VFs for each of them. Other values work as well. 7 is used here because SUTs in OSD supports up to 7 VFs.
#    - detach $passthru_vf_count(currently it is set 3) vfs randomly from host
#    - hotplug one VF to the domain.
#    - hot unplug the VF from the domain
#    - hot plug the remaining VFs to the domain.
#    - reboot the domain.
#    - unplug these VFs from domain.
#    - for each of the plugging/unplugging step above, check domain network status and host&guest status.
# Maintainer: Julie CAO <JCao@suse.com>, qe-virt@suse.de

use base "virt_feature_test_base";
use strict;
use warnings;
use utils;
use testapi;
use virt_autotest::common;
use version_utils qw(is_sle);
use virt_autotest::utils;
use virt_autotest::virtual_network_utils qw(save_guest_ip test_network_interface);

our $log_dir = "/tmp/sriov_pcipassthru";
our $vm_xml_save_dir = "/tmp/download_vm_xml";

sub run_test {
    my $self = shift;

    #set up ssh, packages and iommu on host
    prepare_host();

    #clean up test logs
    script_run "[ -d $log_dir ] && rm -rf $log_dir; mkdir -p $log_dir";

    #save original guest configuration file in case of restore in post_fail_hook()
    save_guests_xml_for_change($vm_xml_save_dir);

    #get the SR-IOV device BDF and interface
    my @host_pfs;
    @host_pfs = find_sriov_ethernet_devices();

    #get/set necessary variables for test
    my $gateway = script_output "ip r s | grep 'default via' | cut -d ' ' -f3 | sort -u";

    # Back up /etc/resolv.conf as it will refresh by creating VFs
    assert_script_run("cp /etc/resolv.conf /etc/resolv_before_enable_vf.conf");

    # enable 8 vfs for the SR-IOV device on host
    my @host_vfs = enable_vf(@host_pfs);
    record_info("VFs enabled", "@host_vfs");

    # Restore /etc/resolv.conf after VFs are created
    assert_script_run("cp /etc/resolv_before_enable_vf.conf /etc/resolv.conf");
    script_run("cat /etc/resolv.conf");

    foreach my $guest (keys %virt_autotest::common::guests) {
        if (virt_autotest::utils::is_sev_es_guest($guest) ne 'notsev') {
            record_info("Skip SR-IOV test on $guest", "SEV/SEV-ES guest $guest does not support SR-IOV");
            next;
        }
        record_info("Test $guest");
        check_guest_health($guest);
        prepare_guest_for_sriov_passthrough($guest);
        save_network_device_status_logs($guest, "1-initial");

        #detach 3 vf ethernet devices from host
        my @vfs = ();
        my $passthru_vf_count = get_var("PASSTHROUGH_VF_COUNT", '3');    #the number of vfs to be passed through to guests
        for (my $i = 0; $i < $passthru_vf_count; $i++) {

            my %vf;

            #detach the vf from host
            $vf{host_bdf} = $host_vfs[int(rand($#host_vfs + 1))];
            my $j = 0;
            while ($j < $i) {
                #select another vf if the vf has been in the list which is going to be detached
                if ($vf{host_bdf} eq $vfs[$j]->{host_bdf}) {
                    $vf{host_bdf} = $host_vfs[int(rand($#host_vfs + 1))];
                    $j = 0;
                }
                else {
                    $j++;
                }
            }
            $vf{host_id} = detach_vf_from_host($vf{host_bdf});

            #add the vf to the list of passthrough devices
            push @vfs, \%vf;

        }

        #hotplug the first vf to vm
        plugin_vf_device($guest, $vfs[0]);
        #upload test specific logs
        save_network_device_status_logs($guest, "2-after_hotplug_$vfs[0]->{host_id}");
        #check the networking of the plugged interface
        #use br123 as ssh connection
        test_network_interface($guest, gate => $gateway, mac => $vfs[0]->{vm_mac}, net => 'br123');

        #unplug the first vf from vm
        unplug_vf_from_vm($guest, $vfs[0]);
        assert_script_run("virsh nodedev-reattach $vfs[0]->{host_id}", 60);
        record_info("Reattach VF to host", "vm=$guest \nvf=$vfs[0]->{host_id}");
        save_network_device_status_logs($guest, "3-after_hot_unplug_$vfs[0]->{host_id}");

        #plug the remaining vfs to vm
        #test network after reboot as dhcp lease spends time
        for (my $i = 1; $i < $passthru_vf_count; $i++) {
            plugin_vf_device($guest, $vfs[$i]);
            test_network_interface($guest, gate => $gateway, mac => $vfs[$i]->{vm_mac}, net => 'br123') if $i == 1;
            save_network_device_status_logs($guest, $i + 3 . "-after_hotplug_$vfs[$i]->{host_id}");
        }

        #reboot the guest
        record_info("VM reboot", "$guest");
        script_run "ssh root\@$guest 'reboot'";    #don't use assert_script_run, or may fail on xen guests
        wait_guest_online($guest, 30);
        save_network_device_status_logs($guest, $passthru_vf_count + 3 . '-after_guest_reboot');

        #check the remaining vf(s) inside vm
        for (my $i = 1; $i < $passthru_vf_count; $i++) {
            test_network_interface($guest, gate => $gateway, mac => $vfs[$i]->{vm_mac}, net => 'br123');
        }

        #unplug the remaining vf(s) from vm
        for (my $i = 1; $i < $passthru_vf_count; $i++) {
            unplug_vf_from_vm($guest, $vfs[$i]);
            assert_script_run("virsh nodedev-reattach $vfs[$i]->{host_id}", 60);
            record_info("Reattach VF to host", "vm=$guest \nvf=$vfs[$i]->{host_id}");
            save_network_device_status_logs($guest, $passthru_vf_count + 4 + $i . "-after_hot_unplug_$vfs[$i]->{host_id}");
            script_run("timeout 20 ssh root\@$guest 'dmesg' >> $log_dir/dmesg_$guest 2>&1") if $i == $passthru_vf_count - 1;
        }
        script_run "lspci | grep Ethernet";
        save_screenshot;

    }

    #upload network device related logs
    virt_autotest::utils::upload_virt_logs($log_dir, "logs");

    #redefine guest from their original configuration files
    restore_xml_changed_guests("$vm_xml_save_dir/changed_xml");
}


#set up ssh, packages and iommu on host
sub prepare_host {

    #install required packages on host
    zypper_call '-t in pciutils nmap';    #to run 'lspci' and 'nmap' command

    #check IOMMU based on VT-d is supported in Intel x86_64 machines
    if (is_kvm_host && script_run("grep Intel /proc/cpuinfo") == 0) {
        assert_script_run "dmesg | grep -E \"DMAR:.*IOMMU enabled\"";
    }

    #enable pciback debug logs
    script_run "echo \"module xen_pciback +p\" > /sys/kernel/debug/dynamic_debug/control" if is_xen_host;

}


#get the BDF of the PF device on host
sub find_sriov_ethernet_devices {

    #get the BDF of the ethernet devices with SR-IOV
    my $nic_devices = script_output "lspci | grep Ethernet | grep -v 'Virtual Function' | cut -d ' ' -f1";
    my @nic_devices = split("\n", $nic_devices);
    my @sriov_devices;
    foreach (@nic_devices) {
        if ((script_run "lspci -v -s $_ | grep -q 'SR-IOV'") == 0) {
            # Any VFs can be passed through to guests
            # But only those VFs whose pv has physical network connection can get an IP from DHCP server
            my $nic = script_output "ls -l /sys/class/net |grep $_ | awk '{print \$9}'";
            if (script_output("ip link show $nic up") =~ /$nic.* state UP/) {
                push @sriov_devices, $_;
                record_info("Find SR-IOV devices", "$_    $nic");
            }
            else {
                assert_script_run("ip link set $nic up");
                if (script_output("cat /sys/class/net/$nic/carrier") eq '1') {
                    push @sriov_devices, $_;
                    record_info("Find SR-IOV devices", "$_    $nic");
                }
                else {
                    script_run("ip link set $nic down");
                }
            }
        }
    }
    die "Error: No SR-IOV ethernet card on host or no carrier connection to SR-IOV ethernet cards!" unless @sriov_devices;

    return @sriov_devices;
}

#enable 8 virtual functions for the specified physical functions of the SR-IOV network device
sub enable_vf {
    my @pfs = @_;

    #enable VFs for SR-IOV PFs by modifying SYS PCI
    #modifying SYS PCI is much better than passing max_vfs=8 in reloading network device drivers
    #as no network break is required anymore(ie. no sol console is needed or no worries about ip/nic change),
    #also modifying SYS PCI allows to enable specified PFs
    foreach my $pf (@pfs) {
        #enable 7 VFs as all of SR-IOV ethernet cards allow the maxium fv number is beyond 7
        assert_script_run("echo 7 > /sys/bus/pci/devices/0000:$pf/sriov_numvfs");
    }

    my $vf_devices = script_output "lspci | grep Ethernet | grep \"Virtual Function\" | cut -d ' ' -f1";
    my @vfs = split("\n", $vf_devices);

}


#set up guest test environment to enable attach VFs
sub prepare_guest_for_sriov_passthrough {
    my $vm = shift;

    unless (is_kvm_host || is_sle('=12-SP5') && is_fv_guest($vm) && !is_guest_ballooned($vm)) {

        #don't not use 'virsh edit' to change domain.xml because 'virsh define' does some error checking
        my $changed_xml_dir = "$vm_xml_save_dir/changed_xml";
        assert_script_run "virsh dumpxml --inactive $vm > $changed_xml_dir/$vm.xml";
        script_run "virsh destroy $vm";

        #disable memory ballooning for fv guest as it is not supported
        if (is_fv_guest($vm) && is_guest_ballooned($vm)) {
            assert_script_run "sed -i '/<currentMemory/d' $changed_xml_dir/$vm.xml";
            record_info "Disable guest ballooning", "$vm";
        }
        #enable pci-passthrough on sles15sp2+
        #set e820_host for pv guest
        #refer to bug #1167217 and but #1185081 for the reason
        unless (is_fv_guest($vm) && is_sle('<15-SP2')) {
            unless (script_run("xmlstarlet sel -t -c /domain/features $changed_xml_dir/$vm.xml") == 0) {
                assert_script_run "xmlstarlet edit -L -s /domain -t elem -n features -v '' $changed_xml_dir/$vm.xml";
            }
            unless (script_run("xmlstarlet sel -t -c /domain/features/xen $changed_xml_dir/$vm.xml") == 0) {
                assert_script_run "xmlstarlet edit -L -s /domain/features -t elem -n xen -v '' $changed_xml_dir/$vm.xml";
            }
            if (is_sle('>=15-SP2') && script_run("xmlstarlet sel -t -c /domain/features/xen/passthrough $changed_xml_dir/$vm.xml") != 0) {
                assert_script_run "xmlstarlet edit -L \\
                                   -s /domain/features/xen -t elem -n passthrough -v '' \\
                                   -s ////passthrough -t attr -n state -v on \\
                                   $changed_xml_dir/$vm.xml";
            }
            if (is_pv_guest($vm) and script_run("xmlstarlet sel -t -c /domain/features/xen/e820_host $changed_xml_dir/$vm.xml") != 0) {
                assert_script_run "xmlstarlet edit -L \\
                                   -s /domain/features/xen -t elem -n e820_host -v '' \\
                                   -s ////e820_host -t attr -n state -v on \\
                                   $changed_xml_dir/$vm.xml";
            }
        }

        #try undefine with --keep-nvram if undefine fails on uefi guest
        script_run "virsh undefine $vm || virsh undefine $vm --keep-nvram";
        assert_script_run(" ! virsh list --all | grep $vm");
        assert_script_run "virsh define $changed_xml_dir/$vm.xml";
        assert_script_run "virsh start $vm";
        wait_guest_online($vm);
    }

    #passwordless access to guest
    save_guest_ip($vm, name => "br123");    #get the guest ip via key words in 'virsh domiflist'

    # Enable udev debug logs
    my $udev_conf_file = "/etc/udev/udev.conf";
    if (script_run("ssh root\@$vm \"ls $udev_conf_file\"") == 0) {
        script_run "ssh root\@$vm \"sed -i '/udev_log *=/{h;s/^[# ]*udev_log *=.*\\\$/udev_log=debug/};\\\${x;/^\\\$/{s//udev_log=debug/;H};x}' $udev_conf_file\"";
    }

    # Journals with previous reboot
    if (guest_is_sle($vm, '<=15-sp5')) {
        my $journald_conf_file = "/etc/systemd/journald.conf";
        script_run "ssh root\@$vm \"sed -i '/^[# ]*Storage *=/{h;s/^[# ]*Storage *=.*\\\$/Storage=persistent/};\\\${x;/^\\\$/{s//Storage=persistent/;H};x}' $journald_conf_file\"";
        script_run "ssh root\@$vm 'systemctl restart systemd-journald'";
    }

}


#detach a specified vf Ethernet device from host
sub detach_vf_from_host {
    my $device_bdf = shift;

    #change to device id in libvirt
    $device_bdf =~ s/[:\.]/_/g;
    my $device_id = script_output "virsh nodedev-list | grep $device_bdf";

    #detach from host
    assert_script_run "virsh nodedev-detach $device_id";
    record_info("Detach VF from host", "$device_id");

    return $device_id;
}


#plugin a device to vm via libvirt
sub plugin_vf_device {
    my ($vm, $vf) = @_;

    #get neccessary device config from host
    my $host_device_xml = script_output "virsh nodedev-dumpxml $vf->{host_id}";
    $host_device_xml =~ /\<domain\>(\w+)\<\/domain\>.*\<bus\>(\w+)\<\/bus\>.*\<slot\>(\w+)\<\/slot\>.*\<function\>(\w+)\<\/function\>/s;
    my ($dev_domain, $dev_bus, $dev_slot, $dev_func) = ($1, $2, $3, $4);

    #'virsh attach-interface' can plug the network device to guest with the BDF in commandline without a seperate device xml file
    #but the SUSE document use 'virsh attach-device', so the test follows it
    #create the device xml to passthrough to vm
    my $vf_host_addr_xml = "<address type='pci' domain='$dev_domain' bus='$dev_bus' slot='$dev_slot' function='$dev_func'/>";
    assert_script_run("echo \"<interface type='hostdev'>\n  <source>\n    $vf_host_addr_xml\n  </source>\n</interface>\" > $vf->{host_id}.xml", 60);
    script_run("cp $vf->{host_id}.xml $log_dir");

    #attach device to vm
    assert_script_run "virsh -d 1 attach-device $vm $vf->{host_id}.xml --persistent";

    #get the mac address and bdf by parsing the domain xml
    #tips: there may be multiple interfaces and multiple hostdev devices in the guest
    my $nics_count = script_output "virsh dumpxml $vm --inactive | grep -c \"<interface.*type='hostdev'\"";
    my $devs_xml = script_output "virsh dumpxml $vm --inactive | sed -n \"/<interface.*type='hostdev'/,/<\\/devices/p\"";
    $vf->{host_id} =~ /pci_([a-z\d]+)_([a-z\d]+)_([a-z\d]+)_([a-z\d]+)/;
    my ($dom, $bus, $slot, $func) = ($1, $2, $3, $4);    #these are different with those in host_devices.xml
    for (my $i = 0; $i < $nics_count; $i++) {
        $devs_xml =~ /\<interface.*?type='hostdev'.*?\<\/interface\>/s;    #minimal match
        my $nic_xml = $&;
        if ($nic_xml =~ /domain='(0x)?$dom' +bus='(0x)?$bus' +slot='(0x)?$slot' +function='(0x)?$func'/) {

            #get the vf xml in vm config file for later unplugging to use
            $vf->{vm_xml} = $nic_xml;

            #get mac address
            $nic_xml =~ /\<mac.*address='(.*)'/;
            $vf->{vm_mac} = $1;

            #get bdf for guests on KVM
            $nic_xml =~ s/\<source.*\<\/source\>//s;
            if ($nic_xml =~ /bus='(\w+)'.*slot='(\w+)'.*function='(\w+)'/) {
                my ($bus, $slot, $func) = ($1, $2, $3);
                $vf->{vm_bdf} = $bus . ":" . $slot . "." . $func;
            }

            #have to get bdf by other means for guests on XEN
            #pv & fv guest differs a bit in directory archeteture
            else {
                $vf->{vm_bdf} = script_output "ssh root\@$vm \"if [ -e /sys/devices/pci-0/pci????:?? ]; then grep -H '$vf->{vm_mac}' /sys/devices/pci-0/*/*/net/*/address | cut -d '/' -f6; else grep -H '$vf->{vm_mac}' /sys/devices/*/*/net/*/address | cut -d '/' -f5; fi\"";
            }
            die "NO BDF is found for $vf->{vm_mac} within $vm!" unless $vf->{vm_bdf};
            last;

        }
        else {
            $devs_xml =~ s/\<interface.*?type='hostdev'.*?\<\/interface\>//s;
        }
    }

    #print the vf device
    $vf->{vm_bdf} =~ /[a-z\d]+:[a-z\d]+[.:][a-z\d]+/;    #bdf has different format in guests on KVM and XEN
    assert_script_run "ssh root\@$vm \"lspci -vvv -s $vf->{vm_bdf}\"";
    $vf->{vm_nic} = script_output "ssh root\@$vm \"grep '$vf->{vm_mac}' /sys/class/net/*/address | cut -d'/' -f5 | head -n1\"";
    record_info("VF plugged to vm", "$vf->{host_id} \nGuest: $vm\nbdf='$vf->{vm_bdf}'   mac_address='$vf->{vm_mac}'   nic='$vf->{vm_nic}'");
    if ($vf->{vm_nic} eq '') {
        script_output "ssh root\@$vm \"for FILE in /sys/class/net/*/address; do echo \\\$FILE; cat \\\$FILE; done\"";    #for debug
        die "Fail to get NIC in $vm: nic='$vf->{vm_nic}'";
    }
}


#unplug the vf device from guest
sub unplug_vf_from_vm {
    my ($vm, $vf) = @_;

    record_info("Unplug VF from vm", "$vf->{host_id} \nGuest: $vm \nbdf='$vf->{vm_bdf}'   mac='$vf->{vm_mac}'   nic='$vf->{vm_nic}'");

    #bring the nic down
    script_run("ssh root\@$vm 'ifdown $vf->{vm_nic}'", 300);

    #detach vf from guest
    my $vf_xml_file = "vf_in_vm.xml";
    assert_script_run "echo \"$vf->{vm_xml}\" > $vf_xml_file";
    script_run("cp $vf_xml_file $log_dir/unplug_$vf->{host_id}.xml");
    assert_script_run("virsh detach-device $vm $vf_xml_file --persistent", 60);

    #check if the nic is removed from vm
    assert_script_run(" ! ssh root\@$vm \"ip l show $vf->{vm_nic}\"", fail_message => "ERROR: vf is unplugged from vm, but nic still exists!");
}

#print logs for debugging
sub save_network_device_status_logs {
    my ($vm, $test_step) = @_;

    #vm configuration file
    script_run("timeout 20 virsh dumpxml $vm > $log_dir/${vm}_${test_step}.xml");

    my $log_file = "log.txt";
    script_run "echo `date` > $log_file";

    #list domain interface
    print_cmd_output_to_file("virsh domiflist $vm", $log_file);

    #logging device information in guest
    script_run "echo '***** Status & logs inside $vm *****' >> $log_file";
    my $debug_script = "sriov_network_guest_logging.sh";
    download_script($debug_script, machine => $vm, proceed_on_failure => 1) if (${test_step} eq "1-initial");
    script_run("timeout 20 ssh root\@$vm \"~/$debug_script\" >> $log_file 2>&1");

    script_run "mv $log_file $log_dir/${vm}_${test_step}_network_device_status.txt";

}

sub post_fail_hook {
    my $self = shift;

    diag("Module sriov_network_card_pci_passthrough post fail hook starts.");
    foreach (keys %virt_autotest::common::guests) {
        save_network_device_status_logs($_, "post_fail_hook");
        script_run("timeout 20 ssh root\@$_ 'dmesg' >> $log_dir/dmesg_$_ 2>&1");
        check_guest_health($_);
    }
    virt_autotest::utils::upload_virt_logs($log_dir, "network_device_status");
    $self->SUPER::post_fail_hook;
    restore_original_guests($vm_xml_save_dir);

}

sub test_flags {
    #continue subsequent test in the case test restored
    return {fatal => 0};
}

1;
