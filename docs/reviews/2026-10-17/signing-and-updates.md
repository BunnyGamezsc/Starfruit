# BunnyGamezDev signing and Sparkle updates

Added to PR #1 on 2026-10-18 at the owner's request to match Tokscale.

Tokscale's macOS configuration selects the self-signed `BunnyGamezDev`
certificate. Starfruit's build now resolves that exact identity (or an explicit
certificate fingerprint) before replacing build output. A missing or ambiguous
identity is an error. Ad-hoc signing requires an explicit `SIGN_IDENTITY=-`.
The app, SMAPI wrapper and embedded Sparkle executable components are signed.
Hardened runtime uses the same library-validation exception as Tokscale;
Starfruit's unused unsigned-executable-memory exception was removed.

The app certificate is separate from Sparkle's archive authentication. A
dedicated Starfruit Ed25519 key is stored in the local Keychain under account
`com.bunnygamez.starfruit`. The committed `sparkle-public-key.txt` contains only
its public key. Builds embed that key and use the latest Starfruit GitHub
release's `appcast.xml` asset as their feed, matching Tokscale's feed layout.
The appcast generator selects the Starfruit account, checks its public key,
and requires an explicit HTTPS download URL prefix for the release.

The standalone exporter includes the public key. The owner subsequently chose
local builds only: GitHub Actions workflows were removed and exports no longer
include CI configuration. The certificate/private keys remain local and were
not exported or uploaded to GitHub.

Validation used a standalone universal build in a temporary directory. Both
architecture slices compiled, strict deep code-signature verification passed,
and the leaf certificates of all nine app/wrapper/Sparkle components matched
the available BunnyGamezDev identity. The embedded public key, release-feed URL
and runtime entitlement were inspected. A ZIP/appcast was generated using the
dedicated update key, its archive signature was verified, and changing the
archive caused verification to fail. Missing certificates, malformed public
keys and mismatched appcast keys were rejected before replacing output.

The generated appcast is a local signing fixture with a `signing-validation`
download URL, not a published feed. No release was published, no app was
installed or launched, and an actual in-app upgrade remains untested.
BunnyGamezDev signing does not constitute Apple Developer ID signing or
notarization.
