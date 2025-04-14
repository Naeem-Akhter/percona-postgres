#!/usr/bin/perl
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use lib 't';
use Env;

if (!defined($ENV{PERCONA_SERVER_VERSION}))
{
     plan skip_all => "PERCONA_SERVER_VERSION variable not define in the environment.";
}

# Initialize a test cluster
my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init();
my $pgdata = $node->data_dir;

my $percona_expected_server_version = $ENV{PERCONA_SERVER_VERSION};

# Start server
my $rt_value = $node->start;
ok($rt_value == 1, "Start Server");

# Get PG Server version ( e.g 17.4) from pg_config
my $pg_server_version = `pg_config --version | awk {'print \$2'}`;
$pg_server_version=~ s/^\s+|\s+$//g;

# Check pg_config output.
my $pg_config_output = `pg_config --version`;
$pg_config_output=~ s/^\s+|\s+$//g;
cmp_ok($pg_config_output,'eq',"PostgreSQL $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version", "Test pg_config --version output");

# Check psql --version output.
my $psql_version_output = `psql --version`;
$psql_version_output=~ s/^\s+|\s+$//g;
cmp_ok($psql_version_output,'eq',"psql (PostgreSQL) $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version", "Test psql --version output");

# Check postgres --version output.
my $postgres_output = `postgres --version`;
$postgres_output=~ s/^\s+|\s+$//g;
cmp_ok($postgres_output,'eq',"postgres (PostgreSQL) $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version", "Test postgres --version output");

# Check select version() output.
($cmdret, $stdout, $stderr) = $node->psql('postgres', "select version();", extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=on']);
ok($cmdret == 0, "# Get output of select version();");
$stdout=~ s/^\s+|\s+$//g;
like($stdout, "/PostgreSQL $pg_server_version - Percona Server for PostgreSQL $percona_expected_server_version/", "# Test select version() output");

# DROP EXTENSION
$stdout = $node->safe_psql('postgres', 'DROP EXTENSION pg_tde;', extra_params => ['-a']);
ok($cmdret == 0, "DROP PGTDE EXTENSION");

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
