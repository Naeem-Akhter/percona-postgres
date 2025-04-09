#!/usr/bin/perl
use strict;
use warnings;
use File::Basename;
use File::Compare;
use File::Copy;
use Test::More;
use lib 't';
use Env;
use pgtde;

# Get file name and CREATE out file name and dirs WHERE requried
PGTDE::setup_files_dir(basename($0));

# CREATE new PostgreSQL node and do initdb
my $node = PGTDE->pgtde_init_pg();
my $pgdata = $node->data_dir;

if (!defined($ENV{PERCONA_SERVER_VERSION}))
{
     plan skip_all => "PERCONA_SERVER_VERSION variable not define in the environment.";
}

my $percona_expected_server_version = $ENV{PERCONA_SERVER_VERSION};

# UPDATE postgresql.conf to include/load pg_tde library
open my $conf, '>>', "$pgdata/postgresql.conf";
print $conf "shared_preload_libraries = 'pg_tde'\n";
close $conf;

# Start server
my $rt_value = $node->start;
ok($rt_value == 1, "Start Server");

# CREATE EXTENSION and change out file permissions
my ($cmdret, $stdout, $stderr) = $node->psql('postgres', 'CREATE EXTENSION pg_tde;', extra_params => ['-a']);
ok($cmdret == 0, "CREATE PGTDE EXTENSION");
PGTDE::append_to_debug_file($stdout);

# Get PG Server version ( e.g 17.4) from pg_config
my $pg_server_version = `pg_config --version | awk {'print \$2'}`;
$pg_server_version=~ s/^\s+|\s+$//g;

PGTDE::append_to_debug_file($pg_server_version + "df");
PGTDE::append_to_debug_file($percona_expected_server_version);

# Check pg_config output.
my $pg_config_output = `pg_config --version`;
$pg_config_output=~ s/^\s+|\s+$//g;
cmp_ok($pg_config_output,'eq',"PostgreSQL $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version", "Test pg_config --version output");
PGTDE::append_to_debug_file("# Test pg_config --version output");
PGTDE::append_to_debug_file($pg_config_output);

# Check psql --version output.
my $psql_version_output = `psql --version`;
$psql_version_output=~ s/^\s+|\s+$//g;
cmp_ok($psql_version_output,'eq',"psql (PostgreSQL) $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version", "Test psql --version output");
PGTDE::append_to_debug_file("# Test psql --version output");
PGTDE::append_to_debug_file($psql_version_output);

# Check postgres --version output.
my $postgres_output = `postgres --version`;
$postgres_output=~ s/^\s+|\s+$//g;
cmp_ok($postgres_output,'eq',"postgres (PostgreSQL) $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version", "Test postgres --version output");
PGTDE::append_to_debug_file("# Test postgres --version output");
PGTDE::append_to_debug_file($postgres_output);

# Check select version() output.
($cmdret, $stdout, $stderr) = $node->psql('postgres', "select version();", extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=on']);
ok($cmdret == 0, "# Get output of select version();");
$stdout=~ s/^\s+|\s+$//g;
like($stdout, "/PostgreSQL $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version/", "# Test select version() output");
PGTDE::append_to_debug_file("# Test select version() output");
PGTDE::append_to_debug_file($stdout);

# DROP EXTENSION
$stdout = $node->safe_psql('postgres', 'DROP EXTENSION pg_tde;', extra_params => ['-a']);
ok($cmdret == 0, "DROP PGTDE EXTENSION");
PGTDE::append_to_debug_file($stdout);

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
