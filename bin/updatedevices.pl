#PERL

use lib "PREFIX/lib";
use Getopt::Long qw(:config no_ignore_case bundling);
use strict;
use Netdot::DeviceManager;
use Netdot::IPManager;
use Netdot::DNSManager;
use NetAddr::IP;

my $usage = <<EOF;
 usage: $0 [ -v|--verbose ] [ -c, --community <string> ] [ -a|--add-subnets ]
           [ -v, --verbose ] [ -g|--debug ]
           -H|--host <hostname|address> | -d|--db-devices |  -s|--subnet <CIDR block>
    
    -H, --host <hostname|address>  update given host only.
    -s, --subnet <CIDR block>      specify a v4/v6 subnet to discover
    -c, --community <string>       SNMP community string (default "public")
    -d, --db-devices               update only DB existing devices
    -a, --add-subnets              add router-known subnets to database if they do not exist
    -h, --help                     print help (this message)
    -v, --verbose                  be verbose
    -g, --debug                    set syslog level to LOG_DEBUG and print to STDERR
    
EOF
    
my ($device, $host, %devices, $subnet, $dm);
my $comstr ||= "public";
my $db = 0;
my $addsubnets = 0;
my $help = 0;
my $verbose = 0;
my $debug = 0;

# handle cmdline args
my $result = GetOptions( "H|host=s" => \$host,
			 "s|subnet=s" => \$subnet,
			 "c|community:s" => \$comstr,
			 "d|db-devices" => \$db,
			 "a|add-subnets" => \$addsubnets,
			 "h|help" => \$help,
			 "v|verbose" => \$verbose,
			 "g|debug" => \$debug );

if( ! $result ) {
  print $usage;
  die "Error: Problem with cmdline args\n";
}
if( $help ) {
  print $usage;
  exit;
}
if ( ($host && $subnet) || ($host && $db) || ($subnet && $db) ){
  print $usage;
  die "Error: arguments -H, -s and -d are mutually exclusive\n";
}

if ($debug){
  $verbose = 1;
  $dm = Netdot::DeviceManager->new( loglevel => "LOG_DEBUG", foreground => 1 );
}else{
  $dm = Netdot::DeviceManager->new();
}
my $ipm = Netdot::IPManager->new();
my $dns = Netdot::DNSManager->new();
my $success = 0;

if ($host){
    if (my $r = &discover(host => $host, comstr => $comstr)){
	$success = 1;
    }
}elsif($subnet){
    my $net = NetAddr::IP->new($subnet);
    # Make sure we work with the network address
    $net = $net->network();
    for (my $nip = $net+1; $nip < $nip->broadcast; $nip++){
	if(my $ip = $ipm->searchblock($nip->addr)){
	    if ( defined ($device = $ip->interface->device) ){
		# Make sure we don't query the same device more than once
		# (routers have many ips)
		if (exists $devices{$device}){
		    printf ("%s already queried.  Skipping\n", $ip->address);
		    next;
		}
		$devices{$device} = 1;
		unless ( $device->canautoupdate ){
		    printf ("Device %s was set to not auto-update. Skipping \n", $nip->addr) if $verbose;
		    next;
		}
	    }
	    if (my $r = &discover(host => $ip->address)){
		$success = 1;
	    }
	}
	if (my $r = &discover(host => $nip->addr, comstr => $comstr)){
	    $success = 1;
	}
    }
}elsif($db){
    printf ("Going to update all devices currently in the DB\n") if $verbose;
    my @devices = Device->retrieve_all;
    foreach my $device ( @devices ) {
	unless ( $device->canautoupdate ){
	    printf ("Device %s was set to not auto-update. Skipping \n", $host) if $verbose;
	    next;
	}
	if (defined ($device->name->name)){
	    $host = $device->name->name;
	}else{
	    # Get any of its IPs
	    foreach my $if ($device->interfaces){
		if (my $ip = ($if->ips)[0]){
		    $host = $ip->address;
		    last;
		}
	    }
	}
	printf ("Updating %s\n", $host);
	if (my $r = &discover(host => $host)){
	    $success = 1;
	}
    }
}else{
    print $usage;
    die "Error: You need to specify one of -H, -s or -d\n";
}

&build_ip_tree if $success;

sub discover {
    my (%argv) = @_;
    my $r;
    $argv{addsubnets} = 1 if $addsubnets;
    if ( $r = $dm->discover(%argv) ){
	printf ("%s\n", $dm->output) if ($verbose && ! $debug);
    }else{
	printf("Error: %s\n", $dm->error) if $verbose;
    }
    return $r;
}

sub build_ip_tree{
    for my $ver (qw (4 6)){
	unless( $ipm->build_tree($ver) ){
	    printf("Could not rebuild IPv%s space tree!: %s\n", $ver, $ipm->error);
	}else{
	    printf("Rebuilt IPv%s space tree\n", $ver);
	}
    }
}
