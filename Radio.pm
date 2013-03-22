package Plugins::Spotify::Radio;

use strict;

use JSON::XS::VersionOneAndTwo;
use XML::Simple;
use URI::Escape;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::Spotify::RadioProtocolHandler;

my $prefs = preferences('plugin.spotify');

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.spotify.radio',
	'defaultLevel' => 'WARN',
	'description'  => 'Spotify',
});

use constant PLAYLIST_MAXLENGTH => 10;

my @stopcommands = qw(clear loadtracks playtracks load play loadalbum playalbum);

# Spotify radio genre mappings - note this is now quessed as api.h is wrong!
my @radioMenu = (
	{ name => 'Alternative',   genre => 'radio_alternative', id =>      0x1 },
	{ name => 'Black Metal',   genre => 'radio_black_metal', id =>      0x2 },
	{ name => 'Blues',         genre => 'radio_blues',       id =>      0x4 },
	{ name => 'Classical',     genre => 'radio_classical',   id =>      0x8 },
	{ name => 'Country',       genre => 'radio_country',     id =>     0x10 },
	{ name => 'Dance',         genre => 'radio_dance',       id =>     0x20 },
	{ name => 'Death Metal',   genre => 'radio_death_metal', id =>     0x40 },
	{ name => 'Electronic',    genre => 'radio_electronic',  id =>     0x80 },
	{ name => 'Emo',           genre => 'radio_emo',         id =>    0x100 },
	{ name => 'Folk',          genre => 'radio_folk',        id =>    0x200 },
	{ name => 'Hardcore',      genre => 'radio_hardcore',    id =>    0x400 },
	{ name => 'Heavy Metal',   genre => 'radio_heavy_metal', id =>    0x800 },
	{ name => 'Hip-Hop',       genre => 'radio_hip_hop',     id =>   0x1000 },
	{ name => 'Indie',         genre => 'radio_indie',       id =>   0x2000 },
	{ name => 'Jazz',          genre => 'radio_jazz',        id =>   0x4000 },
	{ name => 'Latin',         genre => 'radio_latin',       id =>   0x8000 },
	{ name => 'PoP',           genre => 'radio_pop',         id =>  0x10000 },
	{ name => 'Punk',          genre => 'radio_punk',        id =>  0x20000 },
	{ name => 'Reggae',        genre => 'radio_reggae',      id =>  0x40000 },
	{ name => 'R&B',           genre => 'radio_rnb',         id =>  0x80000 },
	{ name => 'Rock',          genre => 'radio_rock',        id => 0x100000 },
	{ name => 'Singer-Songwriter', genre => 'radio_singer_songwriter', id => 0x200000 },
	{ name => 'Soul',          genre => 'radio_soul',        id => 0x400000 },
	{ name => 'Trance',        genre => 'radio_trance',      id => 0x800000 },
	{ name => '60s',           genre => 'radio_60s',         id =>0x1000000 },
	{ name => '70s',           genre => 'radio_70s',         id =>0x2000000 },
	{ name => '80s',           genre => 'radio_80s',         id =>0x4000000 },
);

my %genreMap = map { $_->{'genre'} => $_->{'id'} } @radioMenu;

sub init {
	Slim::Control::Request::addDispatch(['spotifyradio', '_type'], [1, 0, 0, \&cliRequest]);

	Slim::Control::Request::subscribe(\&commandCallback, [['playlist'], ['newsong', 'delete', @stopcommands]]);
}

sub level {
	my ($client, $callback, $args, $session) = @_;

	$session ||= {};
	my @menu;

	for my $entry (@radioMenu) {
		push @menu, {
			name => $entry->{'name'},
			type => 'audio',
			url  => "spotifyradio:genre:$entry->{genre}",
		};
	}
	
	$callback->(\@menu);
}

sub cliRequest {
	my $request = shift;
 
	my $client = $request->client;
	my $type = $request->getParam('_type'); 

	if (Slim::Player::Playlist::shuffle($client)) {

		if ($client->can('inhibitShuffle')) {
			$client->inhibitShuffle('spotifyradio');
		} else {
			$log->warn("WARNING: turning off shuffle mode");
			Slim::Player::Playlist::shuffle($client, 0);
		}
	}

	if ($type eq 'genre') {
		
		my $genre = $request->getParam('_p2');

		$log->info("spotify radio genre mode, genre: $genre");

		_playRadio($client, { genre => $genre });

	} elsif ($type eq 'artist') {
		
		my $artist = $request->getParam('_p2');

		$log->info("spotify radio artist mode, artist: $artist");

		_playRadio($client, { artist => $artist, rand => 1 });

	} elsif ($type eq 'similar') {
		
		my $artist = $request->getParam('_p2');

		$log->info("spotify radio similar artist mode, artist: $artist");

		_playRadio($client, { similar => $artist, rand => 1 });

	} elsif ($type eq 'playlist') {
		
		my $playlist = $request->getParam('_p2');

		$log->info("spotify radio playlist mode, artist: $playlist");

		_playRadio($client, { playlist => $playlist });

	} elsif ($type eq 'lastfmrec') {

		my $user = $request->getParam('_p2');
		
		$log->info("spotify radio playlist mode, lastfm recommended: $user");

		_playRadio($client, { lastfmrec => $user, rand => 1 });

	} elsif ($type eq 'lastfmsimilar') {

		my $similar = $request->getParam('_p2');
		
		$log->info("spotify radio playlist mode, lastfm similar artist: $similar");

		_playRadio($client, { lastfmsimilar => $similar, rand => 1 });
	}

	$request->setStatusDone();
}

sub _playRadio {
	my $master = shift->master;
	my $args   = shift;
	my $callback = shift;

	if ($args) {
		$master->pluginData('running', 1);
		$master->pluginData('args', $args);
		$master->pluginData('tracks', []);
	} else {
		$args = $master->pluginData('args');
	}

	return unless $master->pluginData('running');

	my $tracks = $master->pluginData('tracks');
	
	my $load = ($master->pluginData('running') == 1);

	my $tracksToAdd = $load ? PLAYLIST_MAXLENGTH : PLAYLIST_MAXLENGTH - scalar @{Slim::Player::Playlist::playList($master)};

	# for similar artists only add one track per artist per call until all artists lists have been fetched
	if ($tracksToAdd && ($args->{'similar'} || $args->{'lastfmrec'} || $args->{'lastfmsimilar'}) && !$args->{'allfetched'}) {
		$tracksToAdd = 1;
	}

	if ($tracksToAdd) {

		my @tracksToAdd;

		while ($tracksToAdd && scalar @$tracks) {

			my ($index, $entry);

			if ($args->{'rand'}) {

				# pick a random track, attempting to avoid one with the same title as last track
				# if called from a callback then pick from within the topmost $callback tracks ie from the most recent fetch
				# ensure the range of indexes considered shrinks as $tracks shrink so we always pick a track from the list
				my $consider = $callback || scalar @$tracks;
				if ($consider > scalar @$tracks) {
					$consider = scalar @$tracks;
				}

				my $tries = 3;
				do {

					$index = -int(rand($consider));

				} while ($tracks->[$index]->{'name'} ne ($master->pluginData('lasttitle') || '') && $tries--);

				$master->pluginData('lasttitle', $tracks->[$index]->{'name'});

			} else {

				# take first track
				$index = 0;
			}

			$entry = splice @$tracks, $index, 1;

			# create remote track obj late to ensure it stays in the S:S:RemoteTrack LRU
			my $obj = Slim::Schema::RemoteTrack->updateOrCreate($entry->{'uri'}, {
				title   => $entry->{'name'},
				artist  => join(", ", map { $_->{'name'} } @{$entry->{'artists'}}),
				album   => $entry->{'album'},
				secs    => $entry->{'duration'} / 1000,
				cover   => $entry->{'cover'},
				tracknum=> $entry->{'index'},
			});

			$obj->stash->{'starred'} = $entry->{'starred'};

			push @tracksToAdd, $obj;

			$tracksToAdd--;
		}

		if (@tracksToAdd) {

			$log->info(($load ? "loading " : "adding ") . scalar @tracksToAdd . " tracks, pending tracks: " . scalar @$tracks);
			
			$master->execute(['playlist', $load ? 'loadtracks' : 'addtracks', 'listRef', \@tracksToAdd])->source('spotifyradio');

			if ($load) {
				$master->pluginData('running', 2);
			}
		}
	}

	if ($tracksToAdd > 0 && !$callback) {

		if ($args->{'genre'}) {

			$log->info("fetching radio tracks from spotifyd");

			fetchRadioTracks($master, $tracks, $args);

		} elsif ($args->{'artist'}) {

			$log->info("fetching artist tracks from spotifyd");

			fetchArtistTracks($master, $tracks, $args);

		} elsif ($args->{'similar'}) {

			$log->info("fetching similar artist tracks from spotifyd");

			fetchSimilarTracks($master, $tracks, $args);

		} elsif ($args->{'playlist'}) {

			$log->info("fetching playlist tracks from spotifyd");

			fetchPlaylistTracks($master, $tracks, $args);

		} elsif ($args->{'lastfmrec'}) {

			$log->info("fetching recommendation from lastfm");

			fetchLastfmTracks($master, $tracks, $args);

		} elsif ($args->{'lastfmsimilar'}) {

			$log->info("fetching similar artists from lastfm");

			fetchLastfmTracks($master, $tracks, $args);
		}
	}
}

sub fetchRadioTracks {
	my ($master, $tracks, $args) = @_;

	my $genreId = $genreMap{ $args->{'genre'} };

	my $url = Plugins::Spotify::Spotifyd->uri("radio.json?g=$genreId");

	_fetchTracks($master, $tracks, $args, $url);
}

sub fetchArtistTracks {
	my ($master, $tracks, $args) = @_;

	my $url = Plugins::Spotify::Spotifyd->uri("$args->{artist}/tracks.json");

	_fetchTracks($master, $tracks, $args, $url);
}

sub fetchSimilarTracks {
	my ($master, $tracks, $args) = @_;

	my $artisturl  = Plugins::Spotify::Spotifyd->uri("$args->{similar}/randtracks.json");
	my $similarurl = Plugins::Spotify::Spotifyd->uri("$args->{similar}/browse.json");

	$log->info("fetching similar artists from spotifyd: $similarurl");
	
	my @urls;

	Slim::Networking::SimpleAsyncHTTP->new(
			
		sub {
			my $http = shift;
			
			if ($master->pluginData('args') != $args) {
				$log->info("ignoring response radio session not current");
				return;
			}

			my $json = eval { from_json($http->content) };

			if ($@) {
				$log->warn($@);
			}

			my $artistCount = scalar @{ $json->{'similarartists'} || [] };

			$log->info("found $artistCount artists");

			my $max = $artistCount > 20 ? 20 : 100;

			push @urls, "$artisturl?max=$max";
			
			for my $similar (@{$json->{'similarartists'} || []}) {

				my $url = Plugins::Spotify::Spotifyd->uri("$similar->{artisturi}/randtracks.json?max=$max");

				push @urls, $url;
			}

			my $cb;

			$cb = sub {
				my $url = shift @urls;

				if (!$url) {
					$args->{'allfetched'} = 1;
					return;
				}

				_fetchTracks($master, $tracks, $args, $url, $cb);
			};

			$cb->();
		}, 
			
		sub {
			$log->warn("error fetching similar artists from spotifyd");
		},
			
		{ timeout => 35 },
			
	)->get($similarurl);
}

sub fetchPlaylistTracks {
	my ($master, $tracks, $args) = @_;

	my $url = Plugins::Spotify::Spotifyd->uri("$args->{playlist}/playlists.json");

	_fetchTracks($master, $tracks, $args, $url);
}

sub fetchLastfmTracks {
	my ($master, $tracks, $args) = @_;

	my $lastfmurl;

	my @artists;

	if (my $user = $args->{'lastfmrec'}) {

		$log->info("fetching recommended artists from lastfm for user: $user");

		$lastfmurl = "http://ws.audioscrobbler.com/1.0/user/" . URI::Escape::uri_escape_utf8($user) . "/systemrecs.xml";

	} elsif (my $artist = $args->{'lastfmsimilar'}) {

		$log->info("fetching similar artists from lastfm for arist: $artist");

		push @artists, $artist;

		$lastfmurl = "http://ws.audioscrobbler.com/1.0/artist/" . URI::Escape::uri_escape_utf8($artist) . "/similar.xml";

	} else {
		$log->warn("bad args");
	}
	
	Slim::Networking::SimpleAsyncHTTP->new(
			
		sub {
			my $http = shift;
			
			if ($master->pluginData('args') != $args) {
				$log->info("ignoring response radio session not current");
				return;
			}

			my $xml = eval { XMLin($http->content) };

			if ($@) {
				$log->warn($@);
			}

			if ($args->{'lastfmrec'}) {

				@artists = keys %{$xml->{'artist'}};

			} else {
				for my $entry (@{$xml->{'artist'}}) {
					if (ref $entry eq 'HASH') { 
						push @artists, $entry->{'name'};
					}
				}
			}

			$log->info("found " . scalar @artists . " artists");

			my $max = scalar @artists > 20 ? 20 : 100;

			my $cb;

			$cb = sub {

				if (!scalar @artists) {
					$args->{'allfetched'} = 1;
					return;
				}

				if ($master->pluginData('args') != $args) {
					$log->info("ignoring response radio session not current");
					return;
				}

				my $artist = $args->{'lastfmrec'} ? splice @artists, int(rand(scalar @artists)), 1 : shift @artists;

				$log->info("looking up artist: $artist");
				
				Slim::Networking::SimpleAsyncHTTP->new(
					
					sub {
						my $http = shift;
						
						my $json = eval { from_json($http->content) };
						
						if ($@) {
							$log->warn($@);
						}
						
						# assume direct match is always first entry
						if ($json->{'artists'} && scalar $json->{'artists'} >= 1 && $json->{'artists'}->[0]->{'name'} eq $artist) {
							
							my $artisturi = $json->{'artists'}->[0]->{'uri'};
							
							my $url = Plugins::Spotify::Spotifyd->uri("$artisturi/randtracks.json?max=$max");

							_fetchTracks($master, $tracks, $args, $url, $cb);

						} else {
							$log->info("artist not found: $artist");
							$cb->();
						}
					}, 
					
					sub {
						$log->warn("error searching for artist: $artist");
						$cb->();
					},
					
					{ timeout => 15 }
						
				)->get( Plugins::Spotify::Spotifyd->uri("search.json?o=0&arq=1&q=artist:") . URI::Escape::uri_escape_utf8($artist) );
			};

			$cb->();

		}, 
			
		sub {
			$log->warn("error fetching recommened artists from lastfm");
		},
			
		{ timeout => 15 },
			
	)->get($lastfmurl);
}

sub _fetchTracks {
	my ($master, $tracks, $args, $url, $cb) = @_;

	$log->info("fetching tracks from spotifyd: $url");

	Slim::Networking::SimpleAsyncHTTP->new(
			
		sub {
			my $http = shift;
			
			if ($master->pluginData('args') != $args) {
				$log->info("ignoring response radio session not current");
				return;
			}

			my $json = eval { from_json($http->content) };

			if ($@) {
				$log->warn($@);
			}
			
			push @$tracks, @{$json->{'tracks'} || []};

			my $newtracks = scalar @{$json->{'tracks'} || []};

			$log->info(sub{ sprintf("got %d tracks, pending tracks now %s", $newtracks, scalar @$tracks) });
			
			_playRadio($master, undef, $newtracks) if $newtracks;

			$cb->() if $cb;
		}, 
			
		sub {
			$log->warn("error fetching radio tracks from spotifyd");
			$cb->() if $cb;
		},
			
		{ timeout => 35 },
			
	)->get($url);
}

sub playingRadioStream {
	my $client = shift;
	return $client->master->pluginData('running');
}

sub commandCallback {
	my $request = shift;
	my $client  = $request->client;
	my $master  = $client->master;

	$log->is_debug && $log->debug(sprintf("[%s] %s source: %s", $request->getRequestString, 
		Slim::Player::Sync::isMaster($client) ? 'master' : 'slave',	$request->source || ''));

	return if $request->source && $request->source eq 'spotifyradio';

	return if $request->isCommand([['playlist'], ['play', 'load']]) && $request->getParam('_item') =~ "^spotifyradio:";

	if ($master->pluginData('running')) {

		my $songIndex = Slim::Player::Source::streamingSongIndex($master);
		
		if ($request->isCommand([['playlist'], [@stopcommands]])) {
			
			$log->info("stopping radio");
			
			$master->pluginData('running', 0);
			$master->pluginData('tracks', []);
			$master->pluginData('args', {});
			
			if ($master->can('inhibitShuffle') && $master->inhibitShuffle && $master->inhibitShuffle eq 'spotifyradio') {
				$master->inhibitShuffle(undef);
			}
			
		} elsif ($request->isCommand([['playlist'], ['newsong']] ||
				 ($request->isCommand([['playlist'], ['delete']]) && $request->getParam('_index') > $songIndex)
				)) {
				
			$log->info("playlist changed - checking whether to add or remove tracks");
			
			if ($songIndex && $songIndex >= int(PLAYLIST_MAXLENGTH / 2)) {
				
				my $remove = $songIndex - int(PLAYLIST_MAXLENGTH / 2) + 1;
				
				$log->info("removing $remove track(s) songIndex: $songIndex");
				
				while ($remove--) {
					$master->execute(['playlist', 'delete', 0])->source('spotifyradio');
				}
			}
			
			_playRadio($master);
		}
	}
}

1;
