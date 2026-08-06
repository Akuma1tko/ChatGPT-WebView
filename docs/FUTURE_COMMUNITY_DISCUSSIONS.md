# Future Community Discussions

## Goal

Explore a future **Community** tab where ContextPort users can start discussions, reply, and browse forum-style topics without ContextPort operating a central application server.

## Practical meaning of no server

A worldwide durable forum cannot be literally infrastructure-free. Remote peers need discovery, NAT traversal, and a place to retrieve posts while the author is offline.

The practical requirement should be:

> ContextPort does not operate a proprietary account, database, or forum server.

A global design may still use community-operated relays or bootstrap peers. A truly server-free design can support nearby devices, but not a durable worldwide forum by itself.

## Recommended global approach: Nostr

The first prototype should make ContextPort a client for an open Nostr community.

Potential architecture:

- device-generated signing identity stored in Keychain
- user-configurable public and community relays
- signed forum topics, replies, and reactions
- locally cached read model for offline viewing
- report, mute, block, and moderator controls
- exportable identity and relay configuration

Relevant protocol work to investigate:

- NIP-29 relay-based groups
- NIP-22 comments
- NIP-7D threads
- NIP-25 reactions
- NIP-51 lists for remembered groups and mutes

This provides no ContextPort-owned server, but it is relay-assisted rather than pure device-to-device networking.

## Optional nearby mode

A separate **Nearby Discussions** mode could use Apple Multipeer Connectivity.

Capabilities:

- nearby discovery over infrastructure Wi-Fi, peer-to-peer Wi-Fi, and Bluetooth
- no Internet or remote server required
- signed messages replicated among connected devices
- useful for meetings, classrooms, conferences, and local teams

Limitations:

- only nearby users participate
- backgrounding disconnects sessions and requires reconnection
- it does not create a durable worldwide forum unless content is explicitly bridged elsewhere

## Why not begin with raw libp2p or WebRTC

A custom libp2p forum would provide maximum control, but a production mobile implementation still needs:

- bootstrap and peer discovery
- NAT traversal and relay support
- durable replication while authors are offline
- identity and key recovery
- synchronization and conflict handling
- moderation, spam resistance, and abuse controls

That networking and trust layer would be significantly larger than the forum UI.

## Proposed phases

### Phase 0: architecture prototype

- compare available Nostr Swift libraries with a small direct protocol client
- prove read-only topic and thread loading from multiple relays
- define signing identity and Keychain recovery
- define a local cache schema and deterministic event deduplication
- document relay failure and moderation behavior

### Phase 1: read-only Community tab

- pinned ContextPort announcements
- topic list and threaded discussion reader
- relay health and source visibility
- no posting

### Phase 2: posting and identity

- create or import a signing identity
- create topic, comment, reaction, and deletion request events
- local drafts and a retry queue
- explicit confirmation before publishing attachments

### Phase 3: moderation and resilience

- mute, block, and report controls
- moderator approval and removal workflows
- publication to multiple relays and reconciliation
- offline cache and deterministic deduplication

### Phase 4: optional Nearby Discussions

- Multipeer Connectivity discovery
- encrypted local rooms
- explicit export or bridge into the global community when requested

## Privacy and safety requirements

- never reuse AI-provider cookies or account identities
- never publish a Memory or conversation unless the user explicitly attaches it
- show which relays receive each post
- provide identity backup and export before posting ships
- local block and mute lists must work even when relays do not moderate
- rate limiting and abuse controls are required before public posting ships

## Recommendation

Prototype a **Nostr-backed Community tab** for worldwide discussions and treat **Multipeer Connectivity** as a separate nearby/offline mode.

Do not call the global design serverless. Preferred descriptions are:

- **no ContextPort-owned server**
- **community relay network**
- **open decentralized discussion network**

## Research references

- Nostr NIP-29 relay-based groups: https://nips.nostr.com/29
- Nostr protocol specifications: https://github.com/nostr-protocol/nips
- libp2p overview: https://libp2p.io/docs/
- libp2p publish/subscribe: https://docs.libp2p.io/concepts/pubsub/
- Apple Multipeer Connectivity: https://developer.apple.com/documentation/multipeerconnectivity
