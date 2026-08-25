#!/usr/bin/perl

package Mregd;

use strict;
use warnings;
use base  qw(Net::Server::PreFork);
use POSIX qw(WNOHANG EINTR);
use IO::Socket::SSL;
use IO::Socket::INET6;
use FindBin;
use File::Path qw(make_path);

my $run_dir = '/var/run/mregd';
my $arg     = lc($ARGV[0] || 'usage');

# Config properties this daemon recognizes, for the DEBUG config dump below
my @CONFIG_PROPS = qw(
	conf_file pid_file min_servers max_servers min_spare_servers max_spare_servers
	max_requests log_level log_file user group port
	mregd_host mregd_port mregd_login mregd_password mregd_keepalive_interval
	mregd_socket_username mregd_socket_password
	SSL_verify_mode SSL_ca_path SSL_ca_file SSL_verifycn_name SSL_hostname
);

# Process environment parameters
process_env_variables();

# Initialize new server instance
my $server = Mregd->new();
$server->_initialize();

if ($ENV{DEBUG}) {
	print "Config:\n";
	for my $key (@CONFIG_PROPS) {
		my $value = $server->get_property($key);
		next if !defined $value;
		$value = join(',', @$value) if ref($value) eq 'ARRAY';
		$value = '***'              if $key =~ /password/i;
		print "  $key=$value\n";
	}
}

# start, stop or restart server
if ($arg eq 'start' || $arg eq 'debug' || $arg eq 'foreground') {
	print "Start mregd server\n";

	my $user  = $server->get_property('user');
	my $group = $server->get_property('group');
	if (!-d $run_dir && $user && $group) {
		make_path($run_dir);

		my $uid = getpwnam($user);
		my $gid = getgrnam($group);

		if (defined $uid && defined $gid) {
			chown($uid, $gid, $run_dir)
				or print "Cannot chown $run_dir to $user:$group: $!\n";
			print "Created $run_dir owned by $user:$group\n";
		}
		else {
			print "Cannot resolve user/group $user:$group for $run_dir\n";
		}
	}

	check_config();

	my $config = {};
	if ($arg eq 'start') {
		$config->{'background'} = 1;
		$config->{'setsid'}     = 1;
	}

	# Start server
	$server->run($config);
}
elsif ($arg eq 'stop') {
	my $pid = get_pid();
	print "Stop mregd server (pid $pid)\n";
	kill 'TERM', $pid;
}
elsif ($arg eq 'restart') {
	my $pid = get_pid();
	print "Restart mregd server (pid $pid)\n";
	kill 'HUP', $pid;
}
else {
	print STDERR "USAGE mregd (start|stop|restart|debug|foreground)\n\n";
}

exit;

# The Net::Server default configuration
sub default_values {
	return {
		'conf_file'                  => "$FindBin::Bin/mregd.conf",
		'pid_file'                   => $run_dir . '/mregd.pid',
		'min_servers'                => 2,
		'max_servers'                => 2,
		'min_spare_servers'          => 0,
		'max_spare_servers'          => 0,
		'max_requests'               => 10000,
		'log_level'                  => 3,
		'leave_children_open_on_hup' => 1,
		'port'                       => ['/tmp/mregd.service|unix'],
	};
}

# Check config parameters
sub check_config {

	# Check for required parameters
	foreach my $param (qw(mregd_login mregd_password mregd_host mregd_port mregd_socket_username mregd_socket_password))
	{
		die "Error: $param missing!\n"
			unless $server->get_property($param);
	}

	return;
}

sub process_args {
	my $self = shift;
	$self->SUPER::process_args(@_);

	if ($arg eq 'debug') {

		# Force print to STDERR and log level debug
		$self->{server}{log_file}  = undef;
		$self->{server}{log_level} = 4;
	}
	$self->{server}{multi_port} = 1;

	return;
}

sub accept_multi_port {
	my $self = shift;
	my @waiting;
	while (!(@waiting = $self->{'server'}->{'select'}->can_read())) { }
	return if !@waiting;
	return $waiting[rand @waiting];
}

# Get process id
sub get_pid {
	my $pid_file = $server->get_property('pid_file');

	die "No pid_file found\n" if !defined $pid_file || !-f $pid_file;
	open(my $fh, '<', $pid_file) || die "Config file error";
	my $pid = <$fh>;
	close($fh);
	chomp($pid);

	die "Invalid pid in $pid_file\n" unless $pid =~ /^\d+$/;

	return $pid;
}

# Add mregd options
sub options {
	my $self     = shift;
	my $prop     = $self->{'server'};
	my $template = shift;

	# setup default options
	$self->SUPER::options($template);

	# add mred options
	foreach (
		qw(mregd_host mregd_port mregd_login mregd_password mregd_keepalive_interval
		mregd_socket_username mregd_socket_password
		SSL_verify_mode SSL_ca_path SSL_ca_file SSL_verifycn_name SSL_hostname
		)
		)
	{
		$prop->{$_}     = undef if !defined($prop->{$_}) || (!$prop->{$_} && $prop->{$_} ne '0');
		$template->{$_} = \$prop->{$_};
	}

	return 0;
}

# Set rights for unix socket
sub post_bind_hook {
	my $self = shift;

	# Skip if user != root
	return 0 if $< != 0;

	foreach my $socket_file (grep { /\|unix$/ } @{$self->get_property('port')}) {
		next if !$socket_file || $socket_file !~ /^(.*)\|unix$/om;

		$socket_file = $1;

		chmod(0777, $socket_file)
			or $self->log(0, "chmod error: $!");
	}

	return 0;
}

# Open a new session
sub child_init_hook {
	my $self = shift;

	$self->start_session();

	$self->resetAlarm();

	return 0;
}

sub child_finish_hook {
	my $self = shift;

	#$self->stop_session();

	if ($self->{'SOCKET'}) {
		shutdown($self->{'SOCKET'}, 2);
		$self->{'SOCKET'} = undef;
	}

	$self->log(3, "Close session");

	return 0;
}

# Start session
sub start_session {
	my $self = shift;

	$self->log(3, "Starting new session");

	my %ssl_opts;
	foreach my $opt (
		qw(
		SSL_verify_mode SSL_ca_path SSL_ca_file SSL_verifycn_name SSL_hostname
		)
		)
	{
		my $value = $self->get_property($opt);

		$ssl_opts{$opt} = $value
			if defined $value;
	}

	# Create a new SSL session
	$self->{SOCKET} = IO::Socket::SSL->new(
		Reuse    => 1,
		PeerPort => $self->get_property('mregd_port'),
		PeerAddr => $self->get_property('mregd_host'),
		Proto    => 'tcp',
		%ssl_opts
	);

	if (!$self->{SOCKET}) {
		$self->log(0,
				  "Cannot connect to socket "
				. $self->get_property('mregd_host') . ':'
				. $self->get_property('mregd_port') . ": "
				. IO::Socket::SSL::errstr());
		sleep 30;
		exit 2;
	}

	# Receive server greeting
	my $buf = $self->send_request('READ_GREETING');

	if (!$buf) {
		$self->log(0, "Cannot read from socket!");
		sleep 30;
		exit 2;
	}

	exit 1 if $self->session_login($self->get_property('mregd_login'), $self->get_property('mregd_password'));

	$self->log(2, "[$$] Session login successfull");

	return 0;
} ## end sub start_session

# Check session connection
sub check_session {
	my $self = shift;

	# $self->{SOCKET}
	if (!defined $self->{'SOCKET'} || !$self->{'SOCKET'}->connected) {
		$self->log(2, "Connection lost! Session restart");
		$self->{'SOCKET'} = undef;

		$self->start_session();
	}

	return;
}

# Session login
sub session_login {
	my $self     = shift;
	my $user     = shift;
	my $password = shift;

	# XRRP-Session login
	my $req = "Session\n" . "-Id:$user\n" . "-Password:$password\n" . ".\n";

	my $buf = $self->send_request($req);

	if (!$buf || $buf !~ /^200 /) {
		$self->log(0, "Session login failed: $buf");
		sleep 10;

		return 1;
	}

	$self->{USER} = $user;

	return 0;
}

# Handle client request
sub process_request {
	my $self    = shift;
	my $request = '';
	my $keep    = 1;
	my $timeout = 90;

	# Session auth
	eval {
		alarm(10);
		local $SIG{'ALRM'} = sub {
			$self->log(2, "Request time out!\n");
			alarm(0);
			die("Request time out!");
		};

		# Check username and password
		if (!($self->{'request_authmode'} = $self->auth_connect())) {
			print STDOUT get_response(549, 'Command failed; Login error');
			$keep = 0;
		}
		$self->resetAlarm();
	};
	if ($@) {
		print STDOUT get_response(421, 'Command failed; Timeout');
		$self->resetAlarm();
		return;
	}

	# Get commands loop
	while ($keep) {
		$request = '';
		eval {
			alarm($timeout);
			local $SIG{'ALRM'} = sub {
				$self->log(2, "Read request timeout!\n");
				die("Request time out!");
			};

			my $finish = 0;
			while (!$finish) {
				$_ = <STDIN>;
				if ($_) {
					s/\r//og;
					$request .= $_;
					$finish = 1 if /(^|\n)EOF($|\n)/i;
				}
				else {
					$finish = 1;
				}
			}

			# Disable alarm timer
			alarm(0);
		};
		if ($@) {
			$self->log(2, "Read request error: $@");
			print STDOUT get_response(421, 'Command timeout');
			$self->resetAlarm();
			return 0;
		}

		return unless $request;

		# Send request to server and get the response
		my $response = $self->send_request($request);

		if (!$response) {
			$self->log(0, "Command failed; No Response. Retry");

			# ->connected() can't see a peer that closed while idle (no FIN
			# reaches us until we try I/O) — force a real reconnect for the retry.
			$self->{'SOCKET'} = undef;
			sleep 1;
			$response = $self->send_request($request);

			if (!$response) {
				$self->log(0, "No Response");
				print STDOUT get_response(549, 'Command failed; no response');
				next;
			}
		}

		my $code = '';
		if ($response =~ /^(\d\d\d) ([^\n\r]+)(?:\n|$)/) {
			$code = $1;
			print STDOUT get_response($1, $2);
		}
		else {
			###$code = ?

			print STDOUT $response;
		}

		$self->resetAlarm();

		# Server closing connection.
		$keep = 0 if $code =~ /^(220|420|520|521)$/;
	} ## end while ($keep)

	return;
} ## end sub process_request

sub resetAlarm {
	my $self = shift;

	if ($self->get_property('mregd_keepalive_interval')) {
		my $interval = $self->get_property('mregd_keepalive_interval') + int(rand(9));
		$self->log(4, "Reset Alarm to: $interval");

		$SIG{'ALRM'} = sub {
			$self->send_keep_alive();
			$self->resetAlarm();
			$! = EINTR;
		};

		alarm($interval);
	}
	else {
		alarm(0);
	}

	return 0;
}

sub send_keep_alive {
	my $self = shift;

	$self->log(3, "Send keep alive");

	# Send Describe command to hold the session
	my $request = "[COMMAND]\ncommand=Describe\nEOF\n";
	return $self->send_request($request);
}

# Send request to server and get the response
sub send_request {
	my $self    = shift;
	my $request = shift;

	return 0 unless $request;

	# check session connection
	$self->check_session();

	my $socket = $self->{SOCKET};

	$self->log_request($request);

	# Send request
	if ($request ne 'READ_GREETING') {
		my $wire = $request;
		$wire .= ".\n" if $wire !~ /(^|\n)\.\n$/;

		$wire =~ s/\n/\r\n/omg;

		# A write can succeed even onto a peer that already closed while idle
		# (no FIN reaches us until we try I/O) — but ->connected() reliably
		# flips to false right after such a write. reconnect_if_dead() checks
		# that and, if the peer is gone, reconnects and resends the *whole*
		# original $wire fresh (never a partial resend) — returning true once
		# the caller should stop, since the full request has already gone out.
		my $reconnect_if_dead = sub {
			return 0 if $socket->connected;
			$self->log(2, "Connection lost (detected after write)! Reconnecting");
			$self->{'SOCKET'} = undef;
			$self->check_session();
			$socket = $self->{SOCKET};
			$socket->write($wire);
			return 1;
		};

		# Send a tiny canary chunk first and check the connection before
		# writing the rest: if the peer is already dead, only these few
		# inert bytes (never the actual command/params) went out, so the
		# risk of the backend having received enough to act on is much
		# lower than detecting the dead peer only after the full request
		# was sent. The split point is arbitrary (not a protocol boundary)
		# — this just keeps it uniform for every wire format send_request()
		# handles (login, keepalive, forwarded commands).
		$socket->write(substr($wire, 0, 4));
		if (!$reconnect_if_dead->() && length($wire) > 4) {
			$socket->write(substr($wire, 4));
			$reconnect_if_dead->();
		}
	}

	# Read response
	my $buf = '';
	while (<$socket>) {
		next if /^\s*$/;
		if (/^\s*(\.|EOF)\s*$/) {
			$buf .= "EOF\n";
			last;
		}
		$buf .= $_;
	}

	$buf =~ s/\r\n/\n/omg;

	$self->log_response($buf);

	return $buf;
} ## end sub send_request

sub log_request {
	my $self    = shift;
	my $request = shift;

	my $peeraddr = $self->get_property('peeraddr') || '';

	$self->{LOG} = 'REQUEST ' . $peeraddr . ': ' . $request;

	return;
}

sub log_response {
	my $self     = shift;
	my $response = shift;

	$self->{LOG} .= 'RESPONSE: ' . $response;

	$self->{LOG} =~ s/\r?\n/\t/omg;

	$self->filter_log(\$self->{LOG});

	$self->log(3, $self->{LOG});

	$self->{LOG} = '';

	return;
}

sub filter_log {
	my $self = shift;
	my $log  = shift;

	$$log =~ s/(\s-Password\s*(?:=|:)\s*)(.*)(\s)/$1*****$3/mi;

	return;
}

# Check connection authentication
sub auth_connect {
	my $self = shift;

	print STDOUT "login:";
	my $login = <STDIN>;
	return 0 if !defined $login;
	$login =~ s/\r?\n$//o;
	print STDOUT "password:";
	my $password = <STDIN>;
	return 0 if !defined $password;
	$password =~ s/\r?\n$//o;

	return 1
		if $login eq $self->get_property('mregd_socket_username')
		&& $password eq $self->get_property('mregd_socket_password');

	return 0;
}

sub get_response {
	my $code     = shift;
	my $add_desc = shift;

	return "[RESPONSE]\ncode = $code\ndescription = $add_desc\nEOF\n";
}

sub log {
	my ($self, $level, $msg, @therest) = @_;
	my $prop = $self->{'server'};

	# Add log time only if log file is defined
	$msg = $self->log_time() . ' ' . $msg
		if $prop->{'log_file'}
		&& $prop->{'log_file'} ne 'Sys::Syslog'
		&& $msg !~ /^2\d\d\d\-\d\d\-\d\d /;

	return $self->SUPER::log($level, $msg, @therest);
}

sub log_time {
	my ($sec, $min, $hour, $day, $mon, $year) = localtime;
	return sprintf "%04d-%02d-%02d %02d:%02d:%02d", $year + 1900, $mon + 1, $day, $hour, $min, $sec;
}

sub write_to_log_hook {
	my ($self, $level, $msg) = @_;
	my $prop = $self->{'server'};
	chomp $msg;

	# Remove line return
	$msg =~ s/\r//og;

	# Replace newline by tab
	$msg =~ s/\n/\t/og;

	if ($prop->{'log_file'}) {
		print Net::Server::_SERVER_LOG $msg, "\n";
	}
	elsif ($prop->{'setsid'}) {

		# do nothing ?
	}
	else {
		print STDERR $msg . "\n";
	}

	return;
}

sub process_env_variables {
	my %args = (
		'CONF_FILE'                => 'conf_file',
		'PID_FILE'                 => 'pid_file',
		'MIN_SERVERS'              => 'min_servers',
		'MAX_SERVERS'              => 'max_servers',
		'MIN_SPARE_SERVERS'        => 'min_spare_servers',
		'MAX_SPARE_SERVERS'        => 'max_spare_servers',
		'MAX_REQUESTS'             => 'max_requests',
		'LOG_LEVEL'                => 'log_level',
		'MREGD_XRRP_HOST'          => 'mregd_host',
		'MREGD_XRRP_PORT'          => 'mregd_port',
		'MREGD_XRRP_LOGIN'         => 'mregd_login',
		'MREGD_XRRP_PASSWORD'      => 'mregd_password',
		'MREGD_KEEPALIVE_INTERVAL' => 'mregd_keepalive_interval',
		'MREGD_SOCKET_PORT'        => 'port',
		'MREGD_SOCKET_USERNAME'    => 'mregd_socket_username',
		'MREGD_SOCKET_PASSWORD'    => 'mregd_socket_password',
		'SSL_VERIFY_MODE'          => 'SSL_verify_mode',
		'SSL_CA_PATH'              => 'SSL_ca_path',
		'SSL_CA_FILE'              => 'SSL_ca_file',
		'SSL_VERIFYCN_NAME'        => 'SSL_verifycn_name',
		'SSL_HOSTNAME'             => 'SSL_hostname',
	);
	foreach my $arg (keys %args) {
		next if !defined $ENV{$arg};
		my $value = $ENV{$arg};
		$value = "$value"
			if $value !~ /^\w+$/;
		push @ARGV, '--' . $args{$arg} . '=' . $value;
	}

	return;
}

