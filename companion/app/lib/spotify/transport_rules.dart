// What the Now Playing buttons may do, decided from `nowPlaying.transport`
// (PROTOCOL.md §5) and whether a Spotify account is linked. Pure, so the table
// is pinned by tests and the widget only renders the answer.
//
// The bridge's field says WHO can drive the current source; the app never
// infers it from `source`. Before this existed the buttons were always
// enabled and always dead — `transport` was `none` for AirPlay/Roon (no
// backend) and `spotify-web` for Spotify (which the app ignored).

/// Where a transport command goes.
enum TransportRoute {
  /// `playPause` / `next` / `previous` to the bridge.
  device,

  /// Spotify's Web API, from this phone, aimed at the Q by device name.
  spotifyWeb,

  /// Spotify is playing but no account is linked here: the buttons stay
  /// disabled and the screen offers to connect one.
  spotifyUnlinked,

  /// Nothing this app can act on: disabled buttons, no offer.
  none,
}

TransportRoute transportRoute(String transport, {required bool spotifyLinked}) {
  switch (transport) {
    case 'device':
      return TransportRoute.device;
    case 'spotify-web':
      return spotifyLinked ? TransportRoute.spotifyWeb : TransportRoute.spotifyUnlinked;
    default:
      return TransportRoute.none;
  }
}

bool controlsEnabled(TransportRoute r) =>
    r == TransportRoute.device || r == TransportRoute.spotifyWeb;
