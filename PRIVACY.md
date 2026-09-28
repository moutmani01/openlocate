# Privacy

OpenLocate exists to share your location with people you choose — and nobody else, including
whoever runs the server.

## Defaults
| Setting | Default |
|---|---|
| Location sharing | **Off** |
| Server history retention | **24 hours** |
| Precise location | only while sharing and only as precise as the chosen mode needs |
| Battery level sharing | Off (opt-in) |
| Analytics | **None** — there is no analytics code |
| Crash reporting | Off; if ever added, opt-in and without location data |
| Public profile | None exists |

## What leaves your phone
- **To people you share with:** your location points and, if you opt in, battery level —
  end-to-end encrypted, readable only by them.
- **To everyone in your group:** your display name, end-to-end encrypted to each member.
- **To the server:** your public keys, group memberships, which members you share with,
  encrypted events with an expiry time rounded to the minute, and when you're connected. See
  the [threat model](docs/THREAT_MODEL.md) for exactly what that reveals.

## What we never collect
Phone number, email, IMEI, advertising id, contacts, readable locations, or any
third-party SDK data. There are no ad or tracking SDKs in the app.

## Deletion
- History on the server deletes itself at the retention you pick (max set by the server,
  90 days on the default instance).
- You can delete all your stored history at any time.
- Leaving a group deletes your events and key cards from it. When the last member leaves, the
  whole group is erased.
- Local history on your phone is capped (default 10 000 points) and follows the same retention.

## Server logs
The default backend logs no request content. Operators of self-hosted servers are asked
(and configured by default) to keep request logging off.
