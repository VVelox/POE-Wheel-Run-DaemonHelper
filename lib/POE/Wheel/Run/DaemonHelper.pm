package POE::Wheel::Run::DaemonHelper;

use 5.006;
use strict;
use warnings;
use POE qw( Wheel::Run );
use base 'Error::Helper';
use Algorithm::Backoff::Exponential;
use Sys::Syslog;

=head1 NAME

POE::Wheel::Run::DaemonHelper - 

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use POE::Wheel::Run::DaemonHelper;

    my $foo = POE::Wheel::Run::DaemonHelper->new();
    ...

=head1 SUBROUTINES/METHODS

=head2 new

Required args as below.

    - program :: The program to execute. Either a string or array.
        Default :: undef

Optional args are as below.

    - syslog_name :: The name to use when sending stuff to syslog.
        Default :: DaemonHelper

    - syslog_facility :: The syslog facility to log to.
        Default :: daemon

    - stdout_prepend :: What to prepend to STDOUT lines sent to syslog.
        Default :: ''

    - stderr_prepend :: What to prepend to STDERR lines sent to syslog.
        Default :: Error:

    - max_delay :: Max backoff delay in seconds when a program exits quickly.
        Default :: 90

    - initial_delay :: Initial backoff amount.
        Default :: 2

=cut

sub new {
	my ( $blank, %opts ) = @_;

	my $self = {
		perror        => undef,
		error         => undef,
		errorLine     => undef,
		errorFilename => undef,
		errorString   => "",
		errorExtra    => {
			all_errors_fatal => 1,
			flags            => {
				1 => 'invalidProgram',
				2 => 'optsBadRef',
				3 => 'optsNotInt',
			},
			fatal_flags      => {},
			perror_not_fatal => 0,
		},
		program         => undef,
		syslog_name     => 'DaemonHelper',
		syslog_facility => 'daemon',
		stdout_prepend  => '',
		stderr_prepend  => 'Error: ',
		max_delay       => 90,
		initial_delay   => 2,
		session_created => 0,
		started         => undef,
		started_at      => undef,
		no_restart      => 0,
		backoff         => undef,
		pid             => undef,
	};
	bless $self;

	if ( !defined( $opts{program} ) ) {
		$self->{perror}      = 1;
		$self->{error}       = 1;
		$self->{errorString} = 'program is defined';
		$self->warn;
		return;
	} elsif ( ref( $opts{program} ) ne '' && ref( $opts{program} ) ne 'ARRAY' ) {
		$self->{perror}      = 1;
		$self->{error}       = 1;
		$self->{errorString} = 'ref for program is ' . ref( $opts{program} ) . ', but should be either "" or ARRAY';
		$self->warn;
		return;
	}
	$self->{program} = $opts{program};

	my $ints = {
		'max_delay'     => 1,
		'initial_delay' => 1,
		'short_run'     => 1,
	};

	my @args = [ 'syslog_name', 'syslog_facility', 'stdout_prepend', 'stderr_prepend', 'max_delay', 'initial_delay' ];
	foreach my $arg (@args) {
		if ( defined( $opts{$arg} ) ) {
			if ( ref( $opts{$arg} ) ne 'ARRAY' ) {
				$self->{perror}      = 1;
				$self->{error}       = 2;
				$self->{errorString} = 'ref for ' . $arg . ' is ' . ref( $opts{$arg} ) . ', but should be ""';
				$self->warn;
				return;
			}

			if ( $ints->{$arg} && $opts{arg} !~ /^[0-9]+$/ ) {
				$self->{perror}      = 1;
				$self->{error}       = 3;
				$self->{errorString} = $arg . ' is "' . $opts{arg} . '" and does not match /^[0-9]+$/';
				$self->warn;
				return;
			}

			$self->{$arg} = $opts{arg};
		} ## end if ( defined( $opts{$arg} ) )
	} ## end foreach my $arg (@args)

	eval {
		$self->{backoff} = Algorithm::Backoff::Exponential->new(
			initial_delay         => $self->{initial_delay},
			max_delay             => $self->{max_delay},
			consider_actual_delay => 1,
			delay_on_success      => 1,
		);
	};
	if ($@) {
		die($@);
	}

	return $self;
} ## end sub new

=head2 create_session

This creates the new POE session that will handle this.

=cut

sub create_session {
	my ( $self, %opts ) = @_;

	$self->errorblank;

	POE::Session->create(
		inline_states => {
			_start           => \&on_start,
			got_child_stdout => \&on_child_stdout,
			got_child_stderr => \&on_child_stderr,
			got_child_close  => \&on_child_close,
			got_child_signal => \&on_child_signal,
		},
		heap => { self => $self },
	);

	return;
} ## end sub create_session

=head2 log_message

    - status :: What to log.
      Default :: undef

    - error :: If true, this will set the log level from info to err.
      Default :: 0

=cut

sub log_message {
	my ( $self, %opts ) = @_;

	$self->errorblank;

	if ( !defined( $opts{status} ) ) {
		return;
	}

	my $level = 'info';
	if ( $opts{error} ) {
		$level = 'err';
	}

	eval {
		openlog( $self->{syslog_name}, '', $self->{syslog_facility} );
		syslog( $level, $opts{status} );
		closelog();
	};
	if ($@) {
		warn( 'Errored logging message... ' . $@ );
	}
} ## end sub log_message

=head2 started_at

Returns the PID of the process or undef if it
has not been started.

    my $pid = $dh->pid;
    if ($pid){
        print 'PID is '.$started_at."\n";
    }

=cut

sub pid {
	my ( $self, %opts ) = @_;

	$self->errorblank;

	return $self->{pid};
}

=head2 started

Returns a Perl boolean for if it has been started or not.

    my $started=$dh->started;
    if ($started){
        print 'started as '.$dh->pid."\n";
    }

=cut

sub started {
	my ( $self, %opts ) = @_;

	$self->errorblank;

	return $self->{started};
}

=head2 started_at

Returns the unix time it was (re)started at or undef if it has not
been started.

    my $started_at = $dh->started;
    if ($started_at){
        print 'started at '.$started_at."\n";
    }

=cut

sub started_at {
	my ( $self, %opts ) = @_;

	$self->errorblank;

	return $self->{started_at};
}

sub on_start {

	my $child = POE::Wheel::Run->new(
		StdioFilter  => POE::Filter::Line->new(),
		StderrFilter => POE::Filter::Line->new(),
		Program      => $_[HEAP]{self}->{program},
		StdoutEvent  => "got_child_stdout",
		StderrEvent  => "got_child_stderr",
		CloseEvent   => "got_child_close",
	);

	$_[KERNEL]->sig_child( $child->PID, "got_child_signal" );

	# Wheel events include the wheel's ID.
	$_[HEAP]{children_by_wid}{ $child->ID } = $child;

	# Signal events include the process ID.
	$_[HEAP]{children_by_pid}{ $child->PID } = $child;

	$_[HEAP]{self}->log_message( status => 'Starting... ' . $_[HEAP]{self}->{program} );

	$_[HEAP]{self}->log_message( status => 'Child pid ' . $child->PID . ' started' );

	$_[HEAP]{self}{started}    = 1;
	$_[HEAP]{self}{pid}        = $child->PID;
	$_[HEAP]{self}{started_at} = time;
} ## end sub on_start

sub on_child_stdout {
	my ( $stdout_line, $wheel_id ) = @_[ ARG0, ARG1 ];
	my $child = $_[HEAP]{children_by_wid}{$wheel_id};

	$_[HEAP]{self}->log_message( status => $_[HEAP]{self}->{stdout_prepend} . $stdout_line );
}

sub on_child_stderr {
	my ( $stderr_line, $wheel_id ) = @_[ ARG0, ARG1 ];
	my $child = $_[HEAP]{children_by_wid}{$wheel_id};

	$_[HEAP]{self}->log_message( error => 1, status => $_[HEAP]{self}->{stderr_prepend} . $stderr_line );
}

sub on_child_close {
	my $wheel_id = $_[ARG0];
	my $child    = delete $_[HEAP]{children_by_wid}{$wheel_id};

	# May have been reaped by on_child_signal().
	unless ( defined $child ) {
		return;
	}
	$_[HEAP]{self}->log_message( status => $child->PID . ' closed all pipes.' );
	delete $_[HEAP]{children_by_pid}{ $child->PID };
} ## end sub on_child_close

sub on_child_signal {
	my $error = 0;
	if ( $_[ARG2] ne '0' ) {
		$error = 1,;
	}

	my $child = delete $_[HEAP]{children_by_pid}{ $_[ARG1] };

	$_[HEAP]{self}->log_message( error => $error, status => $_[ARG1] . ' exited with ' . $_[ARG2] );

	if ( defined($child) ) {
		delete $_[HEAP]{children_by_wid}{ $child->ID };
	}

	my $secs;
	if ( !$error ) {
		$secs = $_[HEAP]{self}{backoff}->success;
	} else {
		$secs = $_[HEAP]{self}{backoff}->failure;
	}

	$_[HEAP]{self}->log_message( status => 'restarting in ' . $secs . ' seconds' );

	$_[KERNEL]->delay( _start => 3 );
} ## end sub on_child_signal

=head1 ERROR CODES / FLAGS

=head2 1, invalidProgram

No program is specified.

=head2 2, optsBadRef

The opts has a invlaid ref.

=head2 3, optsNotInt

The opts in question should be a int.

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-poe-wheel-run-daemonhelper at rt.cpan.org>, or through
the web interface at L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Wheel-Run-DaemonHelper>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Wheel::Run::DaemonHelper


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Wheel-Run-DaemonHelper>

=item * Search CPAN

L<https://metacpan.org/release/POE-Wheel-Run-DaemonHelper>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2024 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999


=cut

1;    # End of POE::Wheel::Run::DaemonHelper
