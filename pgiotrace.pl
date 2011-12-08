#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use DBI;
use DBD::Pg;
use File::Basename qw(basename);

my @TRACE = qw(read write _llseek);

sub usage() {
  print STDERR "Usage: $0 --pid <pg_backend_pid> --dsn <pg_data_source_name> [--user <username> --password <password>]\n";
}

select STDERR; $|=1;
select STDOUT; $|=1;

my %parms = (
	     'pid' => '',
	     'dsn' => '',
	     'user' => '',
	     'pass' => ''
	    );

my $ret = GetOptions(
		     'pid=s' => \$parms{'pid'},
		     'dsn=s' => \$parms{'dsn'},
		     'username=s' => \$parms{'username'},
		     'password=s' => \$parms{'password'},
		     );
if( ! $ret ) {
  die usage();
}

print STDERR "Fetching relfilenodes... ";
my $dbh = DBI->connect(sprintf('DBI:Pg:%s', $parms{'dsn'}), $parms{'username'}, $parms{'password'});
if( ! $dbh ) {
  die sprintf("Error connecting to '%s': %s\n", $parms{'dsn'}, $DBI::errstr);
}

my $sth = $dbh->prepare("SELECT class.relfilenode AS file, ns.nspname || '.' || relname AS relation FROM pg_class AS class, pg_namespace AS ns WHERE class.relnamespace = ns.oid ORDER BY file");
if( ! $sth ) {
  die sprintf("Error preparing SELECT statement: %s\n", $DBI::errstr);
}

$sth->execute;
my %backendFdMap;
while( my $row = $sth->fetchrow_hashref ) {
  $backendFdMap{$row->{'file'}} = $row->{'relation'};
}

$dbh->disconnect;

print STDERR "Done.\n";

my $strace = sprintf("strace -r -p %s -e trace=%s 2>&1", $parms{'pid'}, join(',', @TRACE));

print STDERR sprintf("Attaching to backend with PID '%s'... ", $parms{'pid'});
if( not open(STRACE, '-|', $strace) ) {
  die sprintf("Error running '%s'.", $strace);
}
print STDERR sprintf("Done.\n");

my %openFdMap = getOpenFdMap($parms{'pid'});

print STDERR "Backend open fd map:\n";
foreach my $fd (keys %openFdMap) {
  print STDERR sprintf("  fd '%s' -> %s\n", $fd, $openFdMap{$fd});
}
print STDERR "\n";

my $line;
my ($time, $syscall, $fd, $args, $exitcode);
while( $line = <STRACE> ) {
  if( ! ($line =~ m/^
		    \s*
		    (?<time>\d+\.\d+)
		    \s+
		    (?<syscall>[a-zA-Z0-9_]+)
		    \(
		    (?<fd>\d+)
		    ,
		    \s*
		    (?<args>[^)]*)
		    \)\s*=\s*
		    (?<exitcode>.*?)
		    $/x) ) {
    next;
  }

  if( exists $openFdMap{$+{'fd'}} ) {
    $fd = $openFdMap{$+{'fd'}};
    print sprintf("%s(%s) = %s (%s)\n", $+{'syscall'}, $fd, $+{'exitcode'}, $+{'time'});
  }
}
close(STRACE);

sub getOpenFdMap {
  my $pid = shift;
  my $dir = sprintf('/proc/%s/fd', $pid);
  if( ! opendir(DIR, $dir) ) {
    return {};
  }
  my $file;
  my $fd;
  my %map;
  while( $file = readdir(DIR) ) {
    next if( $file eq '.' or $file eq '..' );
    $fd = $file;
    $file = sprintf("%s/%s", $dir, $file);
    next if( ! -l $file );
    $file = readlink($file);
    if( $file =~ m/\/(\d+)(\.\d+)?$/ ) {
      $file = $1;
      if( exists $backendFdMap{$file} ) {
	$file = $backendFdMap{$file};
      }
    }
    $map{$fd} = $file;
  }
  closedir(DIR);
  return %map;
}
