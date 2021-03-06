package Bitq;
use Mouse;
use AnyEvent::HTTP qw(http_get);
use AnyEvent::Handle ();
use AnyEvent::Socket ();
use Bit::Vector;
use File::Path ();
use Log::Minimal;
use Bitq::Bencode qw(bdecode);
use Bitq::Peer::Leecher;
use Bitq::Peer::Seeder;
use Bitq::Protocol qw(uncompact_ipv4);
use Bitq::Store;
use Bitq::Tracker::PSGI;

our $VERSION;
our $MONIKER;
BEGIN {
    my $major = 1;
    my $minor = 0;
    my $dev   = 1;
    $VERSION = $dev > 0 ?
        sprintf '%d.%d_%d', $major, $minor, $dev :
        sprintf '%d.%d', $major, $minor
    ;
    $MONIKER = sprintf '%d%s', $major * 1000 + $minor, $dev > 0 ? 'U' : 'S';

    $Log::Minimal::PRINT = sub {
        printf "%s [%s] %s\n", @_;
    };
}

has peer_id => (
    is => 'ro',
    default => sub { $MONIKER },
);
has host => (
    is => 'ro',
    default => '127.0.0.1',
);

has port => (
    is => 'ro',
    isa => 'Int',
    default => 6688
);

has torrents => (
    is => 'ro',
    default => sub { +{} }
);


# XXX RETHINK
has scrape_urls => (
    is => 'ro',
    default => sub { +{} },
);

has peers => (
    is => 'ro',
    default => sub { +{} },
);

has leechers => (
    is => 'ro',
    default => sub { +{} },
);

has work_dir => (
    is => 'rw',
    required => 1,
    trigger => sub {
        my ($self, $new_value) = @_;
        my @subdirs = (
            File::Spec->catdir( $new_value, "work" ),
            File::Spec->catdir( $new_value, "completed" ),
        );
        foreach my $dir (@subdirs) {
            if (! -d $dir) {
                if (! File::Path::make_path( $dir ) || ! -d $dir ) {
                    die "Failed to create directory $dir: $!";
                }
            }
        }
    }
);

has store => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        Bitq::Store->new( app => $self );
    }
);

has tracker => (
    is => 'rw'
);

sub start_tracker {
    my $self = shift;
    my $tracker = Bitq::Tracker::PSGI->new(
        app   => $self,
        store => $self->store,
    );
    $tracker->start;
    $self->tracker( $tracker );

    return $tracker;
}

sub add_leecher {
    my ($self, $info_hash, $peer) = @_;
    $self->leechers->{$info_hash} = $peer;
}

sub add_peer {
    my ($self, $info_hash, $peer) = @_;
    infof "Registering new peer %s", $info_hash;
    $self->peers->{$info_hash} = $peer;
}

sub start {
    my $self = shift;

    infof "Listening to *:%s", $self->port;
    my $guard = AnyEvent::Socket::tcp_server( undef, $self->port,  sub {
        my ($fh, $host, $port) = @_;
        if (! $fh ) {
            infof "Something wrong in tcp_server";
            return;
        }

        infof "New incoming connection from $host:$port";
        Bitq::Peer::Seeder->start(
            app    => $self,
            host   => $host,
            port   => $port,
            handle => AnyEvent::Handle->new(
                fh => $fh,
            ),
        );
    } );

    my $cv = AE::cv {
        undef $guard;
    };
    return $cv;
}

sub find_torrent {
    my ($self, $info_hash) = @_;
    my $torrent = $self->torrents->{ $info_hash };
    return $torrent;
}

sub add_torrent {
    my ($self, $torrent) = @_;

    infof "Adding torrent with hash %s", $torrent->info_hash;

    $self->torrents->{ $torrent->info_hash } = $torrent;

    my $bitfield = $torrent->bitfield;
    if ($bitfield->is_full) {
        infof "We have complete file";
        $self->store->record_completed( {
            address    => $self->host,
            port       => $self->port,
            info_hash  => $torrent->info_hash,
            peer_id    => $self->peer_id,
            tracker_id => $self->peer_id,
        } );
    }

    infof "Finished analyzing torrent $torrent";
    # after we're done, announce
    $self->announce_torrent( $torrent );
}

sub announce_torrent {
    my ($self, $torrent) = @_;

    my $uri = URI->new($torrent->announce);
    $uri->query_form( {
        port       => $self->port || 0,
        peer_id    => $self->peer_id || '',
        info_hash  => $torrent->info_hash || '',
        left       => $torrent->total_size || 0,
        uploaded   => 0,
        downloaded => 0,
        key        => "DUMMY",
        event      => "started", 
        compact    => 1,
    } );

    infof "Annoucing to tracker %s", $uri;

    http_get $uri, sub {
        my ($res, $hdrs) = @_;
        if ( $hdrs->{Status} ne 200 ) {
            local $Log::Minimal::AUTODUMP = 1;
            infof "Something wrong in request to %s: %s", $hdrs->{URL}, $hdrs;
            return;
        }

        my $reply = bdecode( $res );

        local $Log::Minimal::AUTODUMP = 1;
        infof "Tracker replied with %s", $reply;

        return unless $reply->{peers};

        my @peers = uncompact_ipv4($reply->{peers});
        infof "Got peers: %s", \@peers;
        # if we don't have everything completed, connect to peers
        foreach my $peer ( List::Util::shuffle(@peers) ) {
            infof "Torrent incomplete. Starting a leecher to %s", $peer;
            $self->start_download( $torrent, $peer );
        }
    };
}

sub start_download {
    my ($self, $torrent, $host_port) = @_;

    my ($host, $port) = split /:/, $host_port;

    Bitq::Peer::Leecher->start( 
        app     => $self,
        torrent => $torrent,
        host    => $host,
        port    => $port,
        on_disconnect => sub {
            my $peer = shift;
            if (! $peer->torrent->completed) {
                infof "on_disconnect called";
                $self->announce_torrent( $peer->torrent );
            }
        }
    );
}


1;

__END__

=head1 NAME

Bitq - A BitTorrent Client

=head1 SYNOPSIS

    use Bitq;
    # more to come soon

=head1 DESCRIPTION

Bitq is an AnyEvent-powered BitTorrent client.

=head1 CLASS WALKTHROUGH

=head2 Bitq

Bitq is the "application". It oversees the entire operation.

=head2 Bitq::Torrent

Bitq::Torrent represents a torrent file. It can generate torrent file from actual data, or read a torrent and handle it

=head2 Bitq::Peer

Bitq::Peer is the main communication layer. It represents a bi-directional communication channel about a particular torrent.

=head1 METHODS

=head2 add_torrent( $torrent, %opts )

    $client->add_torrent( $torrent, on_complete => sub { ... } );

    my $cv = AE::cv { warn "download done!" };
    $client->add_torrent( $torrent, on_complete => $cv );

=cut
