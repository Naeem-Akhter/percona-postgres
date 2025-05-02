#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use File::Basename;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use lib 't';
use pgtde;
use Time::HiRes qw(time sleep);
use IPC::Run qw(run);
use POSIX ":sys_wait_h";
use File::Temp qw(tempfile);
use POSIX qw(_exit);


PGTDE::setup_files_dir(basename($0));

# Configuration
my $TEST_DURATION = 60;  # 5 minutes total test duration
my $TABLES = 10;
my $THREADS = 4;
my $DB_NAME = 'postgres';
my $VERIFICATION_RETRIES = 3;
my $VERIFICATION_DELAY = 5;

# Initialize nodes

my ($primary, $replica) = setup_servers();

# Prepare test data
run_sysbench_prepare($primary, $DB_NAME, $TABLES, $THREADS);

# Start background processes
my %TASK_PIDS;
my $start_time = time();
my $end_time = $start_time + $TEST_DURATION;

run_in_background(\&run_oltp_read_write, "OLTP Read Write", $primary, $DB_NAME, $TABLES, $THREADS, $TEST_DURATION);
run_in_background(\&run_oltp_delete,     "OLTP Delete",     $primary, $DB_NAME, $TABLES, $THREADS, $TEST_DURATION);
run_in_background(\&run_update_index,    "Update Index",    $primary, $DB_NAME, $TABLES, $THREADS, $TEST_DURATION);
run_in_background(\&perform_node_operations, "node operations", $primary, $replica, $end_time);
run_in_background(\&rotate_keys, "key rotation", $primary, $DB_NAME, $end_time);
run_in_background(\&toggle_table_am, "feature toggle", $primary, $DB_NAME, $end_time);

# Wait for all background processes
diag("Test running for $TEST_DURATION seconds...");
diag("Waiting for all background tasks...");
wait_for_all_background_tasks();
diag("All background tasks completed.");

verfiy_data_on_nodes($primary, $replica, $TABLES);

done_testing();


# ==========  SUBROUTINES ==========

# ========== SERVER MANAGEMENT ==========
sub setup_servers {
    my $primary = PostgreSQL::Test::Cluster->new('primary');
    $primary->init(
        allows_streaming => 1,
	    auth_extra => [ '--create-role', 'repl_role' ]);
    
    $primary->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_tde'");
    $primary->append_conf('postgresql.conf', "default_table_access_method = 'tde_heap'");
    $primary->append_conf('postgresql.conf', "max_connections = 200");
    $primary->append_conf('postgresql.conf', "listen_addresses = '*'");
    $primary->append_conf('pg_hba.conf', "host replication repuser 127.0.0.1/32 trust");

    $primary->start;
    setup_encryption($primary, $DB_NAME);

    # Setup replica
    $primary->backup('backup');
    my $replica = PostgreSQL::Test::Cluster->new('replica');
    $replica->init_from_backup($primary, 'backup', has_streaming => 1);
    $replica->set_standby_mode();
    $replica->start;

    return ($primary, $replica);
}

# Setup pg_tde encryption on the primary node
sub setup_encryption {
    my ($node, $db_name) = @_;
    $node->safe_psql($db_name, 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
    $node->safe_psql($db_name, 
        "SELECT pg_tde_add_global_key_provider_file('global_key_provider', '/tmp/global_keyring.file');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_set_server_key_using_global_key_provider('global_key', 'global_key_provider');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_add_database_key_provider_file('local_key_provider', '/tmp/db_keyring.fil');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_set_key_using_database_key_provider('local_key', 'local_key_provider');");
}

#============= TEST OPERATIONS ==========
sub verfiy_data_on_nodes {
    my ($primary, $replica, $tables) = @_;
    PGTDE::append_to_result_file("-- At primary");
    PGTDE::psql($primary, 'postgres',
    "CREATE TABLE test_enc (x int PRIMARY KEY) USING tde_heap;");
    PGTDE::psql($primary, 'postgres',
        "INSERT INTO test_enc (x) VALUES (1), (2);");

    PGTDE::psql($primary, 'postgres',
        "CREATE TABLE test_plain (x int PRIMARY KEY) USING heap;");
    PGTDE::psql($primary, 'postgres',
        "INSERT INTO test_plain (x) VALUES (3), (4);");

    PGTDE::psql($primary, 'postgres',
        "select * from test_enc;");
    PGTDE::psql($primary, 'postgres',
        "select * from test_plain;");

    $primary->wait_for_catchup('replica');

    PGTDE::append_to_result_file("-- At replica");
    PGTDE::psql($replica, 'postgres',
        "select * from test_enc;");
    PGTDE::psql($replica, 'postgres',
        "select * from test_plain;");

    for my $i (1..$tables) {
        my ($primary_count, $replica_count);
        $primary_count = $primary->safe_psql($DB_NAME, "SELECT COUNT(*) FROM sbtest$i;");
        $replica_count = $replica->safe_psql($DB_NAME, "SELECT COUNT(*) FROM sbtest$i;");
        is($primary_count, $replica_count, "Table sbtest$i consistency check.Primary: $primary_count, Replica: $replica_count");
    }
    # Compare the expected and out file
    my $compare = PGTDE->compare_results();

    is($compare, 0,
        "Compare Files: $PGTDE::expected_filename_with_path and $PGTDE::out_filename_with_path files."
    );
    return 0;
}

# === Run parallel tasks ===
# This function runs a subroutine in the background and tracks its PID
sub run_in_background {
    my ($sub, $name, @args) = @_;

    my $pid = fork();
    if (!defined $pid) {
        die "Cannot fork: $!";
    } elsif ($pid == 0) {
        # Child process
        eval {
            diag("Starting background task: $name");
            $sub->(@args);
            diag("Completed background task: $name");
            POSIX::_exit(0);
        };
        if ($@) {
            diag("Error in $name: $@");
            POSIX::_exit(1);
        }
    } else {
        # Parent process
        $TASK_PIDS{$pid} = $name;
        diag("Started $name (PID: $pid)");
    }
}

sub wait_for_all_background_tasks {
    for my $pid (keys %TASK_PIDS) {
        my $name = $TASK_PIDS{$pid};
        my $waited = waitpid($pid, 0);
        my $status = $? >> 8;
        diag("Background task '$name' (PID $pid) exited with status $status");
    }
}

# ========== SYSBENCH FUNCTIONS ==========
# This function runs sysbench prepare to create the test tables
sub run_sysbench_prepare {
    my ($node, $db_name, $tables, $threads) = @_; 
    my $user = `whoami`;
    chomp($user);
    my $port = $node->port;
	my $oltp_insert = '/usr/share/sysbench/oltp_insert.lua';
	my $bulk_insert = '/usr/share/sysbench/bulk_insert.lua';

	my @prepare_cmd = (
		'sysbench', $oltp_insert,
		"--pgsql-user=$user",
		"--pgsql-db=$db_name",
		'--db-driver=pgsql',
		"--pgsql-port=$port",
		"--threads=$threads",
		"--tables=$tables",
		'--table-size=1000',
		'prepare'
	);

    diag("Preparing sysbench data...");
	run \@prepare_cmd or die "sysbench prepare failed on " . $node->name . ": $?";

	my @bulk_cmd = (
		'sysbench', $bulk_insert,
		"--pgsql-user=$user",
		"--pgsql-db=$db_name",
		'--db-driver=pgsql',
		"--pgsql-port=$port",
		"--threads=$threads",
		"--tables=$tables",
		'--table-size=1000'
	);

    diag("Running sysbench bulk insert...");
	run \@bulk_cmd or die "sysbench bulk insert failed on " . $node->name . ": $?";
    diag("Sysbench data preparation completed.");
}

sub run_sysbench_script {
    my ($node, $db_name, $script, $tables, $threads, $duration) = @_;

    my $user = `whoami`;
    chomp($user);
    my $port = $node->port;
    my $end_time = time() + $duration;

    while (time() < $end_time) {
        my @cmd = (
            'sysbench', $script,
            "--pgsql-user=$user",
            "--pgsql-db=$db_name",
            '--db-driver=pgsql',
            "--pgsql-port=$port",
            "--threads=$threads",
            "--tables=$tables",
            "--time=30",
            '--report-interval=1',
            'run'
        );

        diag("Running sysbench workload chunk: $script");
        system(@cmd);

        if ($? != 0) {
            diag("Sysbench $script chunk failed, retrying in 5s...");
            sleep(5);
            eval {
                $node->psql($db_name, 'SELECT 1');
            };
            if ($@) {
                diag("Server not responding during $script, waiting for recovery...");
                sleep(10);
            }
        }
    }
}

sub run_oltp_read_write {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/oltp_read_write.lua',
                        $tables, $threads, $duration);
}

sub run_oltp_delete {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/oltp_delete.lua',
                        $tables, $threads, $duration);
}

sub run_update_index {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/oltp_update_index.lua',
                        $tables, $threads, $duration);
}


# ========== TOGGLE OPERATIONS ==========
# This function randomly performs operations on the primary and replica nodes
# such as crashing, restarting, and promoting/demoting.
sub perform_node_operations {
    my ($primary, $replica, $end_time) = @_;
    
    while (time() < $end_time) {
        my $operation = int(rand(5));
        
        if ($operation == 0) {
            # Crash primary
            diag("Crashing primary node...");
            eval { $primary->stop('immediate') };
            sleep(5 + rand(10));
            diag("Restarting primary node...");
            eval { $primary->start() };
        }
        elsif ($operation == 1) {
            # Crash replica
            diag("Crashing replica node...");
            eval { $replica->stop('immediate') };
            sleep(5 + rand(10));
            diag("Restarting replica node...");
            eval { $replica->start() };
        }
        elsif ($operation == 2) {
            # Restart primary cleanly
            diag("Restarting primary node cleanly...");
            eval { $primary->restart() };
        }
        # elsif ($operation == 3) {
        #     # Promote replica
        #     diag("Promoting replica...");
        #     eval { $replica->promote() };
        #     sleep(5);
        #     # Demote back to replica
        #     diag("Demoting back to replica...");
        #     $replica->stop();
        #     $replica->set_standby_mode();
        #     $replica->start();
        # }
        else {
            # Just wait
            sleep(10);
        }
        
        # Random delay between operations
        sleep(5 + rand(15));
    }
}

# This function randomly rotates keys and toggles WAL encryption
sub rotate_keys {
    my ($node, $db_name, $end_time) = @_;
    
    while (time() < $end_time) {
        my $operation = int(rand(3));
        
        if ($operation == 0) {
            # Rotate WAL key
            my $rand = int(rand(1000000)) + 1;
            diag("Rotating WAL key...");
            eval {
                $node->safe_psql($db_name,
                    "SELECT pg_tde_set_server_key_using_global_key_provider('server_key_$rand', 'global_key_provider', 'true');"
                );
            };
        }
        elsif ($operation == 1) {
            # Rotate master key
            my $rand = int(rand(1000000)) + 1;
            diag("Rotating master key...");
            eval {
                $node->safe_psql($db_name,
                    "SELECT pg_tde_set_key_using_database_key_provider('db_key_$rand', 'local_key_provider', 'true');"
                );
            };
        }
        else {
            # Toggle WAL encryption
            my $value = (int(rand(2)) == 0) ? "on" : "off";
            diag("Setting WAL encryption to $value");
            eval {
                $node->safe_psql($db_name,
                    "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
                );
                $node->restart();
            };
        }
        
        sleep(10 + rand(20));
    }
}

# This function randomly changes the access method of a table between heap and tde_heap
sub toggle_table_am {
    my ($node, $db_name, $end_time) = @_;
    
    while (time() < $end_time) {
        my $table = int(rand($TABLES)) + 1;
        my $heap = (int(rand(2)) == 0) ? "heap" : "tde_heap";
        
        diag("Changing table sbtest$table to use $heap");
        eval {
            $node->safe_psql($db_name,
                "ALTER TABLE sbtest$table SET ACCESS METHOD $heap;"
            );
        };
        
        sleep(5 + rand(15));
    }
}
