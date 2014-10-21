package Test::POE::Client::TCP;

use strict;
use warnings;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Filter::Line);
use Socket;
use Carp qw(carp croak);
use vars qw($VERSION);

$VERSION = '0.02';

sub spawn {
  my $package = shift;
  my %opts = @_;
  $opts{lc $_} = delete $opts{$_} for keys %opts;
  my $options = delete $opts{options};
  my $autoconnect = delete $opts{autoconnect};
  if ( $autoconnect and !( $opts{address} and $opts{port} ) ) {
     carp "You must provide both 'address' and 'port' parameters when specifying 'autoconnect'\n";
     return;
  }
  my $self = bless \%opts, $package;
  $self->{_prefix} = 'testc_';
  $self->{session_id} = POE::Session->create(
	object_states => [
	   $self => { shutdown       => '_shutdown',
		      send_event     => '__send_event',
		      send_to_server => '_send_to_server',
		      disconnect     => '_disconnect',
		      terminate      => '_terminate',
		      connect	     => '_connect',
	            },
	   $self => [ qw(_start register unregister _socket_up _socket_fail _conn_input _conn_error _conn_flushed _send_to_server __send_event _disconnect) ],
	],
	heap => $self,
	( ref($options) eq 'HASH' ? ( options => $options ) : () ),
	args => [ $autoconnect ],
  )->ID();
  return $self;
}

sub session_id {
  return $_[0]->{session_id};
}

sub shutdown {
  my $self = shift;
  $poe_kernel->call( $self->{session_id}, 'shutdown' );
}

sub connect {
  my $self = shift;
  $poe_kernel->call( $self->{session_id}, 'connect' );
}

sub _start {
  my ($kernel,$self,$sender,$autoconnect) = @_[KERNEL,OBJECT,SENDER,ARG0];
  $self->{session_id} = $_[SESSION]->ID();

  if ( $self->{alias} ) {
	$kernel->alias_set( $self->{alias} );
  } 
  else {
	$kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );
  }

  if ( $kernel != $sender ) {
    my $sender_id = $sender->ID;
    $self->{events}->{$self->{_prefix} . 'all'}->{$sender_id} = $sender_id;
    $self->{sessions}->{$sender_id}->{'ref'} = $sender_id;
    $self->{sessions}->{$sender_id}->{'refcnt'}++;
    $kernel->refcount_increment($sender_id, __PACKAGE__);
    $kernel->post( $sender, $self->{_prefix} . 'registered', $self );
    $kernel->detach_myself();
  }

  $kernel->yield( 'connect' ) if $autoconnect and $self->{address} and $self->{port};
  return;
}

sub _connect {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $args;
  if ( ref( $_[ARG0] ) eq 'HASH' ) {
    $args = { %{ $_[ARG0] } };
  } 
  else {
    $args = { @_[ARG0..$#_] };
  }
  $args->{lc $_} = delete $args->{$_} for keys %{ $args };
  unless ( $self->{address} and $self->{port} ) {
    unless ( $args->{address} and $args->{port} ) {
      carp "You must provide both 'address' and 'port' parameters\n";
      return;
    }
    $self->{address} = $args->{address}; 
    $self->{port} = $args->{port};
  }

  $self->{localaddr} = $args->{localaddr} if $args->{localaddr};
  $self->{localport} = $args->{localaddr} if $args->{localport};

  if ( $self->{socket} ) {
    carp "Already connected. Disconnect and call 'connect' again\n";
    return;
  }

  if ( $self->{factory} ) {
    carp "Connection already in progress\n";
    return;
  }
  
  $self->{factory} = POE::Wheel::SocketFactory->new(
    RemoteAddress  => $self->{address},
    RemotePort     => $self->{port},
    ( defined $self->{address} ? ( BindAddress => $self->{localaddr} ) : () ),
    ( defined $self->{port} ? ( BindPort => $self->{localport} ) : () ),
    SuccessEvent   => '_socket_up',
    FailureEvent   => '_socket_fail',
    SocketDomain   => AF_INET,             # Sets the socket() domain
    SocketType     => SOCK_STREAM,         # Sets the socket() type
    SocketProtocol => 'tcp',               # Sets the socket() protocol
    Reuse          => 'yes',               # Lets the port be reused
  );

  return;
}

sub _socket_up {
  my ($kernel,$self,$socket,$peeraddr,$peerport) = @_[KERNEL,OBJECT,ARG0..ARG2];
  my $sockaddr = inet_ntoa( ( unpack_sockaddr_in ( CORE::getsockname $socket ) )[1] );
  my $sockport = ( unpack_sockaddr_in ( CORE::getsockname $socket ) )[0];
  $peeraddr = inet_ntoa( $peeraddr );

  delete $self->{factory};

  $self->{socket} = POE::Wheel::ReadWrite->new(
    Handle => $socket,
    _get_filters(
        $self->{filter},
        $self->{inputfilter},
        $self->{outputfilter}
    ),
    InputEvent => '_conn_input',
    ErrorEvent => '_conn_error',
    FlushedEvent => '_conn_flushed',
  );

  $self->_send_event( $self->{_prefix} . 'connected', $peeraddr, $peerport, $sockaddr, $sockport );
  return;
}

sub _get_filters {
    my ($client_filter, $client_infilter, $client_outfilter) = @_;
    if (defined $client_infilter or defined $client_outfilter) {
      return (
        "InputFilter"  => _load_filter($client_infilter),
        "OutputFilter" => _load_filter($client_outfilter)
      );
      if (defined $client_filter) {
        carp(
          "Filter ignored with InputFilter or OutputFilter"
        );
      }
    }
    elsif (defined $client_filter) {
     return ( "Filter" => _load_filter($client_filter) );
    }
    else {
      return ( Filter => POE::Filter::Line->new(), );
    }

}

# Get something: either arrayref, ref, or string
# Return filter
sub _load_filter {
    my $filter = shift;
    if (ref ($filter) eq 'ARRAY') {
        my @args = @$filter;
        $filter = shift @args;
        if ( _test_filter($filter) ){
            return $filter->new(@args);
        } else {
            return POE::Filter::Line->new(@args);
        }
    }
    elsif (ref $filter) {
        return $filter->clone();
    }
    else {
        if ( _test_filter($filter) ) {
            return $filter->new();
        } else {
            return POE::Filter::Line->new();
        }
    }
}

# Test if a Filter can be loaded, return sucess or failure
sub _test_filter {
    my $filter = shift;
    my $eval = eval {
        (my $mod = $filter) =~ s!::!/!g;
        require "$mod.pm";
        1;
    };
    if (!$eval and $@) {
        carp(
          "Failed to load [$filter]\n" .
          "Reason $@\nUsing defualt POE::Filter::Line "
        );
        return 0;
    }
    return 1;
}

sub _socket_fail {
  my ($kernel,$self,$operation,$errnum,$errstr,$wheel_id) = @_[KERNEL,OBJECT,ARG0..ARG3];
  carp "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
  delete $self->{factory};
  $self->_send_event( $self->{_prefix} . 'socket_failed', $operation, $errnum, $errstr );
  return;
}

sub disconnect {
  my $self = shift;
  $poe_kernel->call( $self->{session_id}, 'disconnect', @_ );
}

sub _disconnect {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  return unless $self->{socket};
  $self->{_quit} = 1;
  return 1;
}

sub terminate {
  my $self = shift;
  $poe_kernel->call( $self->{session_id}, 'terminate', @_ );
}

sub _terminate {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  return unless $self->{socket};
  delete $self->{socket};
  $self->_send_event( $self->{_prefix} . 'disconnected' );
  return 1;
}

sub _conn_input {
  my ($kernel,$self,$input,$id) = @_[KERNEL,OBJECT,ARG0,ARG1];
  $self->_send_event( $self->{_prefix} . 'input', $input );
  return;
}

sub _conn_error {
  my ($self,$errstr,$id) = @_[OBJECT,ARG2,ARG3];
  return unless $self->{socket};
  delete $self->{socket};
  $self->_send_event( $self->{_prefix} . 'disconnected' );
  return;
}

sub _conn_flushed {
  my ($self,$id) = @_[OBJECT,ARG0];
  return unless $self->{socket};
  if ( $self->{BUFFER} ) {
    my $item = shift @{ $self->{BUFFER} };
    unless ( $item ) {
      delete $self->{BUFFER};
      $self->_send_event( $self->{_prefix} . 'flushed' );
      return;
    }
    $self->{socket}->put($item);
    return;
  }
  unless ( $self->{_quit} ) {
    $self->_send_event( $self->{_prefix} . 'flushed' );
    return;
  }
  delete $self->{socket};
  $self->_send_event( $self->{_prefix} . 'disconnected' );
  return;
}

sub _shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  delete $self->{factory};
  delete $self->{socket};
  $kernel->alarm_remove_all();
  $kernel->alias_remove( $_ ) for $kernel->alias_list();
  $kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ ) unless $self->{alias};
  $self->_unregister_sessions();
  return;
}

sub register {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL, OBJECT, SESSION, SENDER, ARG0 .. $#_];

  unless (@events) {
    warn "register: Not enough arguments";
    return;
  }

  my $sender_id = $sender->ID();

  foreach (@events) {
    $_ = $self->{_prefix} . $_ unless /^_/;
    $self->{events}->{$_}->{$sender_id} = $sender_id;
    $self->{sessions}->{$sender_id}->{'ref'} = $sender_id;
    unless ($self->{sessions}->{$sender_id}->{refcnt}++ or $session == $sender) {
      $kernel->refcount_increment($sender_id, __PACKAGE__);
    }
  }

  $kernel->post( $sender, $self->{_prefix} . 'registered', $self );
  return;
}

sub unregister {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL,  OBJECT, SESSION,  SENDER,  ARG0 .. $#_];

  unless (@events) {
    warn "unregister: Not enough arguments";
    return;
  }

  $self->_unregister($session,$sender,@events);
  undef;
}

sub _unregister {
  my ($self,$session,$sender) = splice @_,0,3;
  my $sender_id = $sender->ID();

  foreach (@_) {
    $_ = $self->{_prefix} . $_ unless /^_/;
    my $blah = delete $self->{events}->{$_}->{$sender_id};
    unless ( $blah ) {
	warn "$sender_id hasn't registered for '$_' events\n";
	next;
    }
    if (--$self->{sessions}->{$sender_id}->{refcnt} <= 0) {
      delete $self->{sessions}->{$sender_id};
      unless ($session == $sender) {
        $poe_kernel->refcount_decrement($sender_id, __PACKAGE__);
      }
    }
  }
  undef;
}

sub _unregister_sessions {
  my $self = shift;
  my $testd_id = $self->session_id();
  foreach my $session_id ( keys %{ $self->{sessions} } ) {
     if (--$self->{sessions}->{$session_id}->{refcnt} <= 0) {
        delete $self->{sessions}->{$session_id};
	$poe_kernel->refcount_decrement($session_id, __PACKAGE__) 
		unless ( $session_id eq $testd_id );
     }
  }
}

sub __send_event {
  my( $self, $event, @args ) = @_[ OBJECT, ARG0, ARG1 .. $#_ ];
  $self->_send_event( $event, @args );
  return;
}

#sub send_event {
#  my $self = shift;
#  $poe_kernel->post( $self->{session_id}, '__send_event', @_ );
#}

sub _send_event  {
  my $self = shift;
  my ($event, @args) = @_;
  my $kernel = $POE::Kernel::poe_kernel;
  my %sessions;

  $sessions{$_} = $_ for (values %{$self->{events}->{$self->{_prefix} . 'all'}}, values %{$self->{events}->{$event}});

  $kernel->post( $_ => $event => @args ) for values %sessions;
  undef;
}

sub send_to_server {
  my $self = shift;
  $poe_kernel->call( $self->{session_id}, '_send_to_server', @_ );
}

sub _send_to_server {
  my ($kernel,$self,$output) = @_[KERNEL,OBJECT,ARG0];
  return unless $self->{socket};
  return unless $output;

  if ( ref $output eq 'ARRAY' ) {
    my $first = shift @{ $output };
    $self->{BUFFER} = $output if scalar @{ $output };
    $self->{socket}->put($first) if defined $first;
    return 1;
  }

  $self->{socket}->put($output);
  return 1;
}

q{Putting the test into POE};

__END__

=head1 NAME

Test::POE::Client::TCP - A POE Component providing TCP client services for test cases

=head1 SYNOPSIS

  use strict;
  use Socket;
  use Test::More tests => 15;
  use POE qw(Wheel::SocketFactory Wheel::ReadWrite Filter::Line);
  use Test::POE::Client::TCP;
  
  my @data = (
    'This is a test',
    'This is another test',
    'This is the last test',
  );
  
  POE::Session->create(
    package_states => [
  	'main' => [qw(
  			_start
  			_accept
  			_failed
  			_sock_in
  			_sock_err
  			testc_registered
  			testc_connected
  			testc_disconnected
  			testc_input
  			testc_flushed
  	)],
    ],
    heap => { data => \@data, },
  );
  
  $poe_kernel->run();
  exit 0;
  
  sub _start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];
    $heap->{listener} = POE::Wheel::SocketFactory->new(
        BindAddress    => '127.0.0.1',
        SuccessEvent   => '_accept',
        FailureEvent   => '_failed',
        SocketDomain   => AF_INET,             # Sets the socket() domain
        SocketType     => SOCK_STREAM,         # Sets the socket() type
        SocketProtocol => 'tcp',               # Sets the socket() protocol
        Reuse          => 'on',                # Lets the port be reused
    );
    $heap->{testc} = Test::POE::Client::TCP->spawn();
    return;
  }
  
  sub _accept {
    my ($kernel,$heap,$socket) = @_[KERNEL,HEAP,ARG0];
    my $wheel = POE::Wheel::ReadWrite->new(
        Handle       => $socket,
        InputEvent   => '_sock_in',
        ErrorEvent   => '_sock_err',
    );
    $heap->{wheels}->{ $wheel->ID } = $wheel;
    return;
  }
  
  sub _failed {
    my ($kernel,$heap,$operation,$errnum,$errstr,$wheel_id) = @_[KERNEL,HEAP,ARG0..ARG3];
    die "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
    return;
  }
  
  sub _sock_in {
    my ($heap,$input,$wheel_id) = @_[HEAP,ARG0,ARG1];
    pass('Got input from client');
    $heap->{wheels}->{ $wheel_id }->put( $input ) if $heap->{wheels}->{ $wheel_id };
    return;
  }
  
  sub _sock_err {
    my ($heap,$wheel_id) = @_[HEAP,ARG3];
    pass('Client disconnected');
    delete $heap->{wheels}->{ $wheel_id };
    return;
  }
  
  sub testc_registered {
    my ($kernel,$sender,$object) = @_[KERNEL,SENDER,ARG0];
    pass($_[STATE]);
    my $port = ( sockaddr_in( $_[HEAP]->{listener}->getsockname() ) )[0];
    $kernel->post( $sender, 'connect', { address => '127.0.0.1', port => $port } );
    return;
  }
  
  sub testc_connected {
    my ($kernel,$heap,$sender) = @_[KERNEL,HEAP,SENDER];
    pass($_[STATE]);
    $kernel->post( $sender, 'send_to_server', $heap->{data}->[0] );
    return;
  }
  
  sub testc_flushed {
    pass($_[STATE]);
    return;
  }
  
  sub testc_input {
    my ($heap,$input) = @_[HEAP,ARG0];
    pass('Got something back from the server');
    my $data = shift @{ $heap->{data} };
    ok( $input eq $data, "Data matched: '$input'" );
    unless ( scalar @{ $heap->{data} } ) {
      $heap->{testc}->terminate();
      return;
    }
    $poe_kernel->post( $_[SENDER], 'send_to_server', $heap->{data}->[0] );
    return;
  }
  
  sub testc_disconnected {
    my ($heap,$state) = @_[HEAP,STATE];
    pass($state);
    delete $heap->{wheels};
    delete $heap->{listener};
    $heap->{testc}->shutdown();
    return;
  }

=head1 DESCRIPTION

Test::POE::Client::TCP is a L<POE> component that provides a TCP client framework for inclusion in 
client component test cases, instead of having to roll your own.

Once registered with the component, a session will receive events related to connections made, disconnects,
flushed output and input from the specified server.

=head1 CONSTRUCTOR

=over 

=item spawn

Takes a number of optional arguments:

  'alias', set an alias on the component;
  'address', the remote address to connect to;
  'port', the remote port to connect to;
  'options', a hashref of POE::Session options;
  'filter', specify a POE::Filter to use for client connections, default is POE::Filter::Line;
  'inputfilter', specify a POE::Filter for client input;
  'outputfilter', specify a POE::Filter for output to clients;
  'localaddr', specify that connections be made from a particular local address;
  'localport', specify that connections be made from a particular port;
  'autoconnect', set to a true value to make the poco connect immediately;

The semantics for C<filter>, C<inputfilter> and C<outputfilter> are the same as for L<POE::Component::Server::TCP> in that one
may provide either a C<SCALAR>, C<ARRAYREF> or an C<OBJECT>.

If the component is C<spawn>ed within another session it will automatically C<register> the parent session
to receive C<all> events.

C<address> and C<port> are optional within C<spawn>, but if they aren't specified they must be provided to subsequent C<connect>s. If 
C<autoconnect> is specified, C<address> and C<port> must also be defined.

=back

=head1 METHODS

=over

=item connect

Initiates a connection to the given server. Takes a number of parameters:

  'address', the remote address to connect to;
  'port', the remote port to connect to;
  'localaddr', specify that connections be made from a particular local address, optional;
  'localport', specify that connections be made from a particular port, optional;

C<address> and C<port> are optional if they have been already specified during C<spawn>.

=item session_id

Returns the POE::Session ID of the component.

=item shutdown

Terminates the component. It will terminate any pending connects or connections.

=item send_to_server

Send some output to the connected server. The first parameter is a string of text to send. This parameter may also be 
an arrayref of items to send to the client. If the filter you have used requires an arrayref as
input, nest that arrayref within another arrayref.

=item disconnect

Places the server connection into pending disconnect state. Set this, then send an applicable message to the server 
using C<send_to_server()> and the server connection will be terminated.

=item terminate

Immediately disconnects a server conenction.

=back

=head1 INPUT EVENTS

These are events that the component will accept:

=over

=item register

Takes N arguments: a list of event names that your session wants to listen for, minus the 'testc_' prefix.

Registering for 'all' will cause it to send all TESTC-related events to you; this is the easiest way to handle it.

=item unregister

Takes N arguments: a list of event names which you don't want to receive. If you've previously done a 'register' for a particular event which you no longer care about, this event will tell the poco to stop sending them to you. (If you haven't, it just ignores you. No big deal).

=item connect

Initiates a connection to the given server. Takes a number of parameters:

  'address', the remote address to connect to;
  'port', the remote port to connect to;
  'localaddr', specify that connections be made from a particular local address, optional;
  'localport', specify that connections be made from a particular port, optional;

C<address> and C<port> are optional if they have been already specified during C<spawn>.

=item shutdown

Terminates the component. It will terminate any pending connects or connections.

=item send_to_server

Send some output to the connected server. The first parameter is a string of text to send. This parameter may also be 
an arrayref of items to send to the client. If the filter you have used requires an arrayref as
input, nest that arrayref within another arrayref.

=item disconnect

Places the server connection into pending disconnect state. Set this, then send an applicable message to the server 
using C<send_to_server()> and the server connection will be terminated.

=item terminate

Immediately disconnects a server conenction.

=back

=head1 OUTPUT EVENTS

The component sends the following events to registered sessions:

=over

=item testc_registered

This event is sent to a registering session. ARG0 is the Test::POE::Client::TCP object.

=item testd_socket_failed

Generated if the component cannot make a socket connection. 
ARG0 contains the name of the operation that failed. 
ARG1 and ARG2 hold numeric and string values for $!, respectively.

=item testc_connected

Generated whenever a connection is established. ARG0 is the server's IP address, ARG1 is the server's TCP port.
ARG3 is our IP address and ARG4 is our socket port.

=item testc_disconnected

Generated whenever we disconnect from the server.

=item testc_input

Generated whenever the server sends us some traffic. ARG0 is the data sent ( tokenised by whatever POE::Filter you specified ).

=item testc_flushed

Generated whenever anything we send to the server is actually flushed down the 'line'.

=back

=head1 AUTHOR

Chris C<BinGOs> Williams <chris@bingosnet.co.uk>

with code borrowed from L<POE::Component::Server::TCP> by Rocco Caputo, Ann Barcomb and Jos Boumans.

=head1 LICENSE

Copyright C<(c)> Chris Williams, Rocco Caputo, Ann Barcomb and Jos Boumans.

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for details.

=head1 SEE ALSO

L<POE>

L<POE::Component::Server::TCP>

=cut
