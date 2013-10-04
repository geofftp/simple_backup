#!/usr/bin/perl

use strict ;
use warnings ;

use YAML qw(LoadFile) ;
use POSIX qw(cuserid strftime) ;
use Getopt::Long ;
use DDP ;##Debug

our $DEBUG = 0 ; ## For devel.
our $CRON_DEBUG = 1 ;
my ($path) = $0 =~ m!^(.*)/! ;
## Global
##  Needs to be run as /full/path/to/backup/backup.pl so it loads the backup.yaml when run from cron
my $conf = LoadFile("$path/backup.yaml") ;



die "Error: Please run as root.\n"
    unless cuserid eq 'root' ;
$conf->{local_dst} .= substr($conf->{local_dst}, -1, 1) eq "/" ? "" : "/" ;
my %opts ;
GetOptions(
    \%opts, 
    'local-hourly', 'local-daily', 'local-weekly', 'local-monthly',
    'remote-hourly', 'remote-daily', 'remote-weekly', 'remote-monthly',
    'database|db'
    );
## Run main program.
do_backup( \%opts ) ;
#
#######################################################################################
sub do_backup {
    my $opts = shift ;
    ## Check the local/remote dirs are created depending on the options passed.
    my $dir_check = join ' ', keys %$opts ;
    ## Checks
    $dir_check =~ /local/ &&
	check_local_dirs() ;
    $dir_check =~ /remote/ &&
	check_remote_dirs() ;
    ## Database
    $opts{database} &&
	database_backup() ;
    ## Local Backups
    $opts{'local-hourly'} &&
	local_hourly_backup() ;
    $opts{'local-daily'} &&
	local_daily_backup() ;
    $opts{'local-weekly'} &&
	local_weekly_backup() ;
    $opts{'local-monthly'} &&
	local_monthly_backup() ;
    ## Remote Backups
    $opts{'remote-hourly'} &&
	remote_hourly_backup() ;
    $opts{'remote-daily'} &&
	remote_daily_backup() ;
    $opts{'remote-weekly'} && 
	remote_weekly_backup() ;
    $opts{'remote-monthly'} &&
	remote_monthly_backup() ;
}
sub check_local_dirs {
    my $local_dst = $conf->{local_dst} ;
    ### Check we have proper directories for backups.
    -d $local_dst or 
	mkdir($local_dst) ;
    -d $local_dst . '/monthly' or
	mkdir($local_dst . 'monthly') ;
    -d $local_dst . '/weekly' or
	mkdir($local_dst . '/weekly') ;
    -d $local_dst . '/daily' or
	mkdir($local_dst . '/daily') ;
    -d $local_dst . '/hourly' or
	mkdir($local_dst . '/hourly') ;
}
sub check_remote_dirs {
    my $remote_dst = $conf->{remote_dst} ;
    my ($con, $base_dir) ;
    ## Check for base dir.
    if ( $remote_dst =~ /:/ ) {
        ($con, $base_dir) = split /:/, $remote_dst ;
        $base_dir .= substr($base_dir, -1, 1) eq '/' ? '' : '/' ;
    }
    ## Store in conf for future use.
    $conf->{con}      = $con ;
    $conf->{base_dir} = $base_dir ;
    ## Check for the base dir's existence inside remote_cmd and create if it doesn't exist.
    my $ret = remote_cmd("ls $base_dir") ;
    if ( $ret =~ /No such file or directory/ ) {
        $ret = '' ;
        $ret = remote_cmd("mkdir $base_dir") ;
        ## Should be no return here. If there is we have an error to mail about.
        $ret && mail_errors($ret) ;
    }
}
sub local_cmd {
    my $cmd = shift ;
    print "Running local command: $cmd\n" if $DEBUG ;
    return qx/$cmd 2>&1/ ;
}
sub remote_cmd{
    my $cmd = shift ;
    print "Running ssh $conf->{con} $cmd\n" if $DEBUG ;
    return
	qx/ssh $conf->{con} $cmd 2>&1/ ;
}
sub remote_dir_exists {
    my $dir = shift ;
    print "Checking exists with ssh $conf->{con} ls $dir\n" if $DEBUG ;
    my $exists = qx/ssh $conf->{con} ls $dir 2>&1/ ;
    if ( $exists =~ /No such file or directory/ ) {
	print "No such dir.\n" if $DEBUG ;
	return 0 ;
    } else {
	print "exists!\n" if $DEBUG ;
	return 1 ;
    }
}
sub database_backup {
    mail_errors('', "Starting database dumps") if $CRON_DEBUG ;

    unless ( -d $conf->{db_dir} ) {
	system("mkdir -p $conf->{db_dir}") ;
    }
    ###############################################
    ## PostgreSQL
    if ( $conf->{psql_user} ) {
	if ( $conf->{psql_password} ) {
	    ## We create ~/.pgpass with the password for psql.
	    unless ( -e "~/.pgpass" ) {
		system("echo $conf->{psql_password} > ~/.pgpass") ;
		system("chmod 700 ~/.pgpass") ;
	    }
	}
	my $date = strftime("%F", localtime) ;
	## removed date otherwise we'll end up with an ever increasing daily backup
	system("pg_dumpall -U $conf->{psql_user} | gzip > full_psql_dump.gz 2>&1") ;

        ## Now we move the db to the db backup dir.
	my $ret = local_cmd("mv full_psql_dump.gz $conf->{db_dir}") ;

	if ( $ret ) {
	    mail_errors("PostgreSQL database backup full_psql_dump was unsuccessful.") ;
	}
    }
    ################################################
    ## MySQL
    if ( $conf->{mysql_user} ) {
	my $date = strftime("%F", localtime) ;
	if ( $conf->{mysql_password} ) {
	    system("mysqldump -u $conf->{mysql_user} --password=$conf->{mysql_password} --all-databases | gzip > full_mysql_dump.gz 2>&1") ;
	} else {
	    system("mysqldump -u $conf->{mysql_user} --all-databases | gzip > full_mysql_dump.gz 2>&1") ;
	}
	## Now we move the db to the db backup dir.
	my $ret = local_cmd("mv full_mysql_dump.gz $conf->{db_dir}") ;
	if ( $ret ) {
            mail_errors("MySQL database backup full_mysql_dump was unsuccessful.") ;
	}
    }
}
sub local_hourly_backup {
#    mail_errors('', "Starting local hourly backup") if $CRON_DEBUG ;
    my $dirs = $conf->{src} ;
    my $base_dir = $conf->{local_dst} . 'hourly/' ;
    my $hourly =  [
	$base_dir . 'hourly.0',
	$base_dir . 'hourly.1',
	$base_dir . 'hourly.2',
	$base_dir . 'hourly.3'
	] ;
    ## Delete oldest snapshot.
    if ( -d $hourly->[3] ) {
	my $err = local_cmd("rm -rf $hourly->[3]") ;
	$err and mail_errors($err) ;
    }
    if ( -d $hourly->[2]) {
	my $err = local_cmd("mv $hourly->[2] $hourly->[3]") ;
	$err and mail_errors($err) ;
    }
    if ( -d $hourly->[1] ) {
	my $err = local_cmd("mv $hourly->[1] $hourly->[2]") ;
        $err and mail_errors($err) ;
    }
    if ( -d $hourly->[0] ) {
	my $err = local_cmd("cp -al $hourly->[0] $hourly->[1]") ;
	$err and mail_errors($err) ;	
    }
    for my $dir ( @{ $dirs } ) {
	my $exclude ;
	if ( ref $dir ) {
	    $exclude = $dir->{exclude} ;
	    $dir     = $dir->{dir} ;
	}
	$dir .= substr($dir, -1, 1) eq "/" ? "" : "/" ;
	my $dst = $hourly->[0] . $dir ;
	unless ( -d $dst ) {
	    my $err = local_cmd("mkdir -p $dst") ;
	    $err and mail_errors($err) ;
	}
	my $err ;
	if ( $exclude ) {
	    ## -v = verbose, -a = archive mode, --quiet = no errors and --delete will remove
	    ## files from the destination if they've been deleted from the source.
	    $err = local_cmd("rsync -va --exclude-from=$exclude --quiet --delete $dir $dst 2>&1");
	} else {
	    $err = local_cmd("rsync -va --quiet --delete $dir $dst 2>&1") ;
	}
	$err and mail_errors($err) ;
    }
    ## update mtime of hourly.0 to reflect the snapshot time.
    #
    my $err = local_cmd("touch $hourly->[0]") ;
    $err and mail_errors($err) ;
}
sub local_daily_backup {
    mail_errors('', "Starting local daily backup") if $CRON_DEBUG ;

    my $base_dir = $conf->{local_dst} . 'daily/' ;
    my $daily =  [
        $base_dir . 'daily.0',
        $base_dir . 'daily.1',
        $base_dir . 'daily.2',
        $base_dir . 'daily.3'
        ] ;
    ## Delete oldest snapshot.
    if ( -d $daily->[2]) {
	my $err = local_cmd("rm -rf $daily->[2]");
	$err and mail_errors($err) ;
    }
    if ( -d $daily->[1] ) {
        my $err = local_cmd("mv $daily->[1] $daily->[2]") ;
	$err and mail_errors($err) ;
    }
    if ( -d $daily->[0] ) {
        my $err = local_cmd("mv $daily->[0] $daily->[1]") ;
	$err and mail_errors($err) ;
    }
    $base_dir =~ s/daily/hourly/ ;
    my $hourly3 = $base_dir . 'hourly.3/' ;
    ## We check hourly3 exists. If this is the first, second or third run then it won't.
    #
    if ( -d $hourly3 ) {
	my $err = local_cmd("cp -al $hourly3 $daily->[0]") ;
	$err and mail_errors($err) ;
    }
}
sub local_weekly_backup {
    mail_errors('', "Starting local weekly backup") if $CRON_DEBUG ;

    my $base_dir = $conf->{local_dst} . 'weekly/' ;
    my $weekly =  [
        $base_dir . 'weekly.0',
        $base_dir . 'weekly.1',
        $base_dir . 'weekly.2',
        $base_dir . 'weekly.3'
        ] ;
    ## Delete oldest snapshot.
    if ( -d $weekly->[2]) {
        my $err = local_cmd("rm -rf $weekly->[2]") ;
	$err and mail_errors($err) ;
    }
    if ( -d $weekly->[1] ) {
        my $err = local_cmd("mv $weekly->[1] $weekly->[2]") ;
	$err and mail_errors($err) ;
    }
    if ( -d $weekly->[0] ) {
        my $err = local_cmd("mv $weekly->[0] $weekly->[1]") ;
	$err and mail_errors($err) ;
    }
    $base_dir =~ s/weekly/daily/ ;
    my $daily2 = $base_dir . 'daily.2/' ;
    ## We check daily2 exists. If this is the first, second or third run then it won't.
    #
    if ( -d $daily2 ) {
        my $err = local_cmd("cp -al $daily2 $weekly->[0]") ;
	$err and mail_errors($err) ;
    }
}
sub local_monthly_backup {
    mail_errors('', "Starting local monthly backup") if $CRON_DEBUG ;

    my $base_dir = $conf->{local_dst} . 'monthly/' ;
    my $monthly =  [
        $base_dir . 'monthly.0',
        $base_dir . 'monthly.1',
        $base_dir . 'monthly.2',
        $base_dir . 'monthly.3'
        ] ;
    ## Delete oldest snapshot.
    if ( -d $monthly->[1] ) {
        my $err = local_cmd("rm -rf $monthly->[1]") ;
	$err and mail_errors($err) ;
    }
    if ( -d $monthly->[0] ) {
        my $err = local_cmd("mv $monthly->[0] $monthly->[1]") ;
	$err and mail_errors($err) ;
    }
    $base_dir =~ s/monthly/weekly/ ;
    my $weekly2 = $base_dir . 'weekly.2/' ;
    ## We check weekly2 exists. If this is the first, second or third run then it won't.
    #
    if ( -d $weekly2 ) {
        my $err = local_cmd("cp -al $weekly2 $monthly->[0]") ;
	$err and mail_errors($err) ;
    }
}
## Remote backup
sub remote_hourly_backup {
#    mail_errors('', "Starting remote hourly backup") if $CRON_DEBUG ;
    my $dirs = $conf->{src} ;
    my $base_dir = $conf->{base_dir} . 'hourly/' ;
    my $hourly =  [
	$base_dir . 'hourly.0',
	$base_dir . 'hourly.1',
	$base_dir . 'hourly.2',
	$base_dir . 'hourly.3'
	] ;
    ## Delete oldest snapshot.
    if ( remote_dir_exists($hourly->[3]) ) {
	remote_cmd("rm -rf $hourly->[3]") ;
    }
    if ( remote_dir_exists($hourly->[2]) ) {
	remote_cmd("mv $hourly->[2] $hourly->[3]") ;
    }
    if ( remote_dir_exists($hourly->[1]) ) {
	remote_cmd("mv $hourly->[1] $hourly->[2]") ;
    }
    if ( remote_dir_exists($hourly->[0]) ) {
	remote_cmd("cp -al $hourly->[0] $hourly->[1]") ;
    }
    for my $dir ( @{ $dirs } ) {
	$dir .= substr($dir, -1, 1) eq "/" ? "" : "/" ;
	my $dst = $hourly->[0] . $dir ;
	## Check that the destination exists on the remote server.
	unless ( remote_dir_exists($dst) ) {
	    remote_cmd("mkdir -p $dst") ;
	}
	my $err ;
	if ( $DEBUG ) {
	    system("rsync -a --quiet --delete $dir -e ssh $conf->{con}:$dst") ;
	} else {
	    $err = qx/rsync -a --quiet --delete $dir -e ssh $conf->{con}:$dst 2>&1/ ;
	}
	if ( $err ) {
	    mail_errors($err) ;
	}
    }
    ## update mtime of hourly.0 to reflect the snapshot time.
    #
    remote_cmd("touch $hourly->[0]") ;
}
sub remote_daily_backup {
    mail_errors('', "Starting remote daily backup") if $CRON_DEBUG ;

    my $base_dir = $conf->{base_dir} . 'daily/' ;
    my $daily =  [
        $base_dir . 'daily.0',
        $base_dir . 'daily.1',
        $base_dir . 'daily.2',
        $base_dir . 'daily.3'
        ] ;
    ## Delete oldest snapshot.
    if ( remote_dir_exists($daily->[2]) ) {
	remote_cmd("rm -rf $daily->[2]") ;
    }
    if ( remote_dir_exists($daily->[1]) ) {
        remote_cmd("mv $daily->[1] $daily->[2]") ;
    }
    if ( remote_dir_exists($daily->[0]) ) {
        remote_cmd("mv $daily->[0] $daily->[1]") ;
    }
    $base_dir =~ s/daily/hourly/ ;
    my $hourly3 = $base_dir . 'hourly.3/' ;
    ## We check hourly3 exists. If this is the first, second or third run then it won't.
    #
    if ( remote_dir_exists($hourly3) ) {
	remote_cmd("mkdir -p $daily->[0]") ;
	remote_cmd("cp -al $hourly3 $daily->[0]") ;
    }
}	
sub remote_weekly_backup {
    mail_errors('', "Starting remote weekly backup") if $CRON_DEBUG ;

    my $base_dir = $conf->{base_dir} . 'weekly/' ;
    my $weekly =  [
        $base_dir . 'weekly.0',
        $base_dir . 'weekly.1',
        $base_dir . 'weekly.2',
        $base_dir . 'weekly.3'
        ] ;
    ## Delete oldest snapshot.
    if ( remote_dir_exists($weekly->[2]) ) {
        remote_cmd("rm -rf $weekly->[2]") ;
    }
    if ( remote_dir_exists($weekly->[1]) ) {
        remote_cmd("mv $weekly->[1] $weekly->[2]") ;
    }
    if ( remote_dir_exists($weekly->[0]) ) {
        remote_cmd("mv $weekly->[0] $weekly->[1]") ;
    }
    $base_dir =~ s/weekly/daily/ ;
    my $daily2 = $base_dir . 'daily.2/' ;
    ## We check hourly3 exists. If this is the first, second or third run then it won't.
    #
    if ( remote_dir_exists($daily2) ) {
        remote_cmd("mkdir -p $weekly->[0]") ;
        remote_cmd("cp -al $daily2 $weekly->[0]") ;
    }
}
sub remote_monthly_backup {
    mail_errors('', "Starting remote monthly backup") if $CRON_DEBUG ;

    my $base_dir = $conf->{base_dir} . 'monthly/' ;
    my $monthly =  [
        $base_dir . 'monthly.0',
        $base_dir . 'monthly.1',
        $base_dir . 'monthly.2',
        $base_dir . 'monthly.3'
        ] ;
    ## Delete oldest snapshot.
    if ( remote_dir_exists($monthly->[1]) ) {
        remote_cmd("rm -rf $monthly->[1]") ;
    }
    if ( remote_dir_exists($monthly->[0]) ) {
        remote_cmd("mv $monthly->[0] $monthly->[1]") ;
    }
    $base_dir =~ s/monthly/weekly/ ;
    my $weekly2 = $base_dir . 'weekly.2/' ;
    ## We check hourly3 exists. If this is the first, second or third run then it won't.
    #
    if ( remote_dir_exists($weekly2) ) {
        remote_cmd("mkdir -p $monthly->[0]") ;
        remote_cmd("cp -al $weekly2 $monthly->[0]") ;
    }
}
sub mail_errors {
    my $msg = shift ;
    my @caller = caller 1;
    $msg .= "\n\nCalled by $caller[3]\n\n" ;

    my $subject = shift || 'Backup Failure Alert' ;

	my $mail = 'echo "Subject: ' . $conf->{server} . ': ' . $subject . '
From: geoff.servers@gmail.com
To: geoff.servers@gmail.com

' .
$msg . '" | /usr/sbin/ssmtp -vvv geoff.servers@gmail.com' ;

    system("$mail > /dev/null 2>&1");

    ## Let's exit. There may be more errors, but mailing one is enough to trigger an investigation from the admin.
    exit 1 if $subject =~ /Backup Failure Alert/ ; ## Eek!! An evil hack
}


__END__


=head1 NAME

backup.pl


=head1 VERSION

This documentation refers to <backup.pl> version 0.1

=head1 SYNOPSIS

Hourly, Daily, Weekly & Monthly rsync rotation backups with local + remote support and automatic database backup.


=head1 REQUIRED ARGUMENTS



=head1 OPTIONS

Multiple options can be specified, so you can do a --local-hourly and a --local-monthly at the same time, or you can do them individually.

=over 4

=item
--local-hourly

Do a local hourly backup.

=item
--local-daily

Do a local daily backup.

=item
--local-weekly

Do a local weekly backup.

=item
--local-monthly

Do a local monthly backup.

=item
--remote-hourly

Do a remote hourly backup.

=item
--remote-daily

Do a remote daily backup.

=item
--remote-weekly

Do a remote weekly backup.

=item
--remote-monthly

Do a remote monthly backup.

=item
--database|--db=db_backup_dir

Checks for mysql and psql. If it finds either/or it'll backup all databases, tar/gzip them up and move them to the db backup dir that you pass.

=back

=head1 DESCRIPTION

This program is for implementing a rotation backup scheme with daily, hourly, weekly and monthly local and remote backups.
It has built in error checking and will email errors to the email specified in the YAML config.

You can also add in your database details and have PostgreSQL and/or MySQL databases automatically backed up, tar+gzipd and added into the rotations.


=head1 DIAGNOSTICS



=head1 CONFIGURATION AND ENVIRONMENT

backup.yaml is the configuration file. Run backup.pl with backup.yaml in the same directory.

The configuration options are as follows:-

=over 4

=item
server: Earth

The server name. Used in the subject of the error email.

=item
error_email: geoff.servers@gmail.com

The email to send errors to.

=item
local_dst: /root/backup/earth

The local director to put the backup rotations.

=item 
remote_dst: 11909@ch-s011.rsync.net:earth/

The remote bacup destination. This should be something that can be passed to rsync -s

=item 
src:

The directories to backup. See below for usage.

=over 8

=item 
 - /srv/www

=item 
- /etc

=item 
 - 

=over 12

=item 
 dir: /home/jeff/dev

=item  
exclude: dev_exclude.txt

If you have files you want to exclude then specify a hash in yaml with dir and exclude otherwise we just specify the directory as a string.
exclude should be a file containing 1 pattern per line for an exclusion, ie,

=over 1

=item
donot/backup/

=item
dont/backup/*test*/

=item

=back

=item 
- /root/db_backup


=back

=back

=item
psql_user

The psql database username to use for the backup. Optional

=item
psql_password

The pasword for the psql db user. If this option isn't passed or if it's blank then a password won't be used. Optional

=item
mysql_user

The mysql user. Optional.

=item
mysql_password

The mysql password. If blank or not used then no password will be used for the backup. Optional.

=item
db_dir

The directory to move database backup(s) to. Required if you're doing a db backup.

=back

=head1 DEPENDENCIES

This software is dependent on ssmtp, the sendmail simulator for sending error mail. ssmtp supports adding a gmail smtp server for easy-sending, which means we don't have to bother setting up a full MTA on the server.

on CentOS:- yum install ssmtp

=head1 INCOMPATIBILITIES

Will work on all linux versions.


=head1 BUGS AND LIMITATIONS

There are no known bugs in this app.
Please report problems to Geoff T. Parsons <geoff@bluecrushmarketing.com>
Patches are welcome.

=head1 AUTHOR

Geoff T. Parsons <geoff@bluecrushmarketing.com

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2013 Blue Crush Marketing (<geoff@bluecrushmarketing.com>). All rights reserved.

