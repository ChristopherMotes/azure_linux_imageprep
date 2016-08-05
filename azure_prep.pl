#!/usr/bin/perl -w
use strict;
# codifying this for rhel 7 annd rhel 6
# https://azure.microsoft.com/en-us/documentation/articles/virtual-machines-linux-redhat-create-upload-vhd/#rhel67vmware
local $ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin";
my $NETWORK_FILE = "/etc/sysconfig/network";
my $IFACE_FILE  = "/etc/sysconfig/network-scripts/ifcfg-eth0";
my $WAAGENT_DIR = "/var/lib/waagent";
my @UDEV_FILES  = (
    "/lib/udev/rules.d/75-persistent-net-generator.rules",
    "/etc/udev/rules.d/70-persistent-net.rules"
);
my $OSMAJREL = &get_os_major_release;
if ( $OSMAJREL gt 7 || $OSMAJREL lt 6 ) {
    die "I haven't been tested with RHEL $OSMAJREL\n";
}
# we use a hash with null values to get a unique list
my %GRUB_COMMAND_OPTIONS = (
    'rootdelay=300'    => "",
    'console=ttyS0'    => "",
    'earlyprintk=ttyS' => "",
);
my $WAAGENT_FILE = "/etc/waagent.conf";
###### This hash needs command line options I don't care today
my %WAAGENT_SEARCH_HASH = (
    "ResourceDisk.Format"     => "y",
    "ResourceDisk.Filesystem" => "ext4",
    "ResourceDisk.MountPoint" => "/mnt/resource",
    "ResourceDisk.EnableSwap" => "y",
    "ResourceDisk.SwapSizeMB" => "2048",
);
# We start by removing the network manager rpm is it exists
my @rpm_check_command = ( "rpm", '-q', 'NetworkManager' );
my @rpm_remove_command = ( "rpm", '-e', '--nodeps', "NetworkManager" );
my $rpm_check_command_rv = system(@rpm_check_command) != 0
  or system(@rpm_remove_command);
# Now we update the network file
open( NETWORK_HANDLE, ">$NETWORK_FILE" ) or die "cannot open $NETWORK_FILE";
printf NETWORK_HANDLE "NETWORKING=yes\nHOSTNAME=localhost.localdomain\n";
close NETWORK_HANDLE;
# Resetting ifcfg-eth0
open( IFACE_HANDLE, ">$IFACE_FILE" ) or die "cannout open $IFACE_FILE";
printf IFACE_HANDLE
"DEVICE=eth0\nONBOOT=yes\nBOOTPROTO=dhcp\nTYPE=Ethernet\nUSERCTL=no\nPEERDNS=yes\nIPV6INIT=no\n";
close IFACE_HANDLE;
# This section installs the Waagent
# if the yum command fails we just alert about the repo. Subscription manager requires password
# I refuse to script passwords
my @yum_command = ( 'yum', '-q', '-y', 'install', 'WALinuxAgent' );
system(@yum_command) == 0
  or die
"Cannot install  WALinux Agent, check system subscriptions for server-extras (RHEL 7) or EPEL (RHEL 6)";
my @mkdir = ( 'mkdir', '-m', '0700', "$WAAGENT_DIR" );
my @chkconfig_commmand = ( 'chkconfig', 'waagent', 'on' );
# I'm to lazy to check the os for RHEL 7 commands v RHEL 6 here
print
"WARNING: For RHEL 7 chkconfig is depricated. Script requires update when chkconfig is sunset\n";
system(@chkconfig_commmand);
system(@mkdir) unless -d $WAAGENT_DIR;
for (@UDEV_FILES) {
    my @command = ( 'cp', "$_", "$WAAGENT_DIR" );
    system(@command) if -f $_;
}
# Now we update the waagent file
my @backup_waagent_file = ( 'cp', "$WAAGENT_FILE", "${WAAGENT_FILE}.old" );
system(@backup_waagent_file) == 0
  or die "cannot create ${WAAGENT_FILE}.old";
open( WAAGENT_OLD, "<", "${WAAGENT_FILE}.old" );
open( WAAGENT_HANDLE, ">${WAAGENT_FILE}" );
while (<WAAGENT_OLD>) {
    my $outline = $_;
    foreach my $key ( keys %WAAGENT_SEARCH_HASH ) {
        $outline =~ s/$key.*/$key=$WAAGENT_SEARCH_HASH{$key}/g;
    }
    print WAAGENT_HANDLE "$outline";
}
close WAAGENT_OLD;
close WAAGENT_HANDLE;
my @waaagent_deprovision = ( '/usr/sbin/waagent', '-force', '-deprovision' );
system(@waaagent_deprovision) == 0
  or die "waagent deprovision failed";
# Grub changes from OE to OE. We only focus on  RHEL
# grub 6 and grub 7 could probably me merged into a single sub
# and variablized.
if ( $OSMAJREL eq '7' ) {
    &grub_7();
}
elsif ( $OSMAJREL eq '6' ) {
    &grub_6();
}
#now we beat on dracut for a few lines
my @dracut_backup = ( 'cp', '/etc/dracut.conf', '/etc/dracut.prev' );
system(@dracut_backup) == 0
  or die "can't back up dracut file";
open( DRACUT_PREV_HANDLE, "<", "/etc/dracut.prev" );
open( DRACUT_OUT_HANDLE,  ">", "/etc/dracut.conf" );
### This line could eventaully need something bitchcakes (see grub sub for bitchcakes)
# For current purposes this works just fine.
while ( my $outline = <DRACUT_PREV_HANDLE> ) {
    if ( $outline =~ m/add_drivers/ ) {
        $outline = "add_drivers+=\" hv_vmbus hv_netvsc hv_storvsc \"\n";
    }
    print DRACUT_OUT_HANDLE $outline;
}
close DRACUT_OUT_HANDLE;
close DRACUT_PREV_HANDLE;
my @dracut_command = ( "dracut", '-f', '-v' );
system(@dracut_command) == 0
  or die "dracut failed";
# finally we address sshd
my @sshd_config_backup =
  ( 'cp', '/etc/ssh/sshd_config', '/etc/ssh/sshd_config.prev' );
system(@sshd_config_backup) == 0
  or die "can't back up sshd_config file";
open( SSHD_PREV_HANDLE, "<", "/etc/ssh/sshd_config.prev" );
open( SSHD_OUT_HANDLE,  ">", "/etc/ssh/sshd_config" );
while ( my $outline = <SSHD_PREV_HANDLE> ) {
    if ( $outline =~ m/ClientAliveInterval/ ) {
        $outline = "ClientAliveInterval 180\n";
    }
    print SSHD_OUT_HANDLE $outline;
}
sub grub_7() {
    my @grub_backup = ( 'cp', '/etc/default/grub', '/etc/default/grub.prev' );
    system(@grub_backup) == 0
      or die "can't back up grub file";
    open( GRUB_PREV_HANDLE, "<", "/etc/default/grub.prev" );
    open( GRUB_OUT_HANDLE,  ">", "/etc/default/grub" );
    while ( my $outline = <GRUB_PREV_HANDLE> ) {
        my @removes = ( 'rhgb', 'quiet', 'crashkernel=auto' );
        for (@removes) {
            $outline =~ s/$_//g;
        }
        #now we go absolutely bitchcakes
        #we have to put everything as hash keys for uniq ness
        # only futz with GRUB_CMDLINE_LINUX
        if ( $outline =~ m/GRUB_CMDLINE_LINUX/ ) {
            my @split = split "( |=\")", "$outline";
            for (@split) {
                #we have to strip tons of stuff
                unless (m/\"|CMDLINE_LINUX|^\s*$/) {
                    $GRUB_COMMAND_OPTIONS{$_} = "";
                }
            }
            #now we rebuild the line in the file
            $outline = "GRUB_CMDLINE_LINUX=\" ";
            while ( my ( $key, $value ) = each %GRUB_COMMAND_OPTIONS ) {
                $outline = $outline . "$key ";
            }
            $outline = $outline . "\"\n";
        }
        print GRUB_OUT_HANDLE $outline;
    }
    close GRUB_PREV_HANDLE;
    close GRUB_OUT_HANDLE;
    my @grub_command = ( 'grub2-mkconfig', '-o', '/boot/grub2/grub.cfg' );
    system(@grub_command) == 0
      or die "grub2-mkconfig failed";
}
sub grub_6() {
    my $kernel_name = "";
    my @grub_backup =
      ( 'cp', '/boot/grub/menu.lst', '/boot/grub/menu.lst.prev' );
    system(@grub_backup) == 0
      or die "can't back up grub file";
    open( GRUB_PREV_HANDLE, "<", "/boot/grub/menu.lst.prev" );
    open( GRUB_OUT_HANDLE,  ">", "/boot/grub/menu.lst" );
    while ( my $outline = <GRUB_PREV_HANDLE> ) {
        my @removes = ( 'rhgb', 'quiet', 'crashkernel=auto' );
        for (@removes) {
            $outline =~ s/$_//g;
        }
        # RHEL 6 is insaner than rhel 7
        #we have to put everything as hash keys for uniq ness
        # only futz with GRUB_CMDLINE_LINUX
        if ( $outline =~ m/(^\s*kernel\s+\/vmlinuz-\S+)(.*)/ ) {
            $kernel_name = "$1";
            my $kernel_line = "$2";
            my @split = split '\s+', "$kernel_line";
            for (@split) {
                #we have to strip tons of stuff
                unless (m/^\s*$/) {
                    $GRUB_COMMAND_OPTIONS{$_} = "";
                }
            }
            #now we rebuild the line in the file
            $outline = "$kernel_name ";
            while ( my ( $key, $value ) = each %GRUB_COMMAND_OPTIONS ) {
                $outline = $outline . "$key ";
            }
            $outline = $outline . "\n";
        }
        print $outline;
        print GRUB_OUT_HANDLE $outline;
    }
    close GRUB_PREV_HANDLE;
    close GRUB_OUT_HANDLE;
}
sub get_os_major_release {
    open( HANDLE, "<", "/etc/redhat-release" );
    while (<HANDLE>) {
        if (/.*(\d+\.\d+).*/) {
            my @split = split( '\.', $1 );
            return $split[0];
        }
    }
    close HANDLE;
}
