# GitHub release updater

SpaceTree uses Sparkle 2.10.0 to verify, download, install, and relaunch updates.
The framework is pinned in SwiftPM and embedded in universal app bundles,
including its installer helpers and license. There is no custom app-replacement
script. The updater starts only inside an `.app` with a valid HTTPS feed URL and
Ed25519 public key. Automatic checks, automatic installation, and system profiling
default to off. Sparkle persists user choices; SpaceTree does not reset them on launch.

## Enable release publishing

1. Resolve dependencies with `swift package resolve`. Sparkle's tools are in
   `.build/artifacts/sparkle/Sparkle/bin/`.
2. Run that directory's `generate_keys`. Keep the generated private key in your
   Keychain and back it up securely. Copy the printed public key into the GitHub
   repository **Actions variable** `SPARKLE_PUBLIC_ED_KEY`.
3. Export the key with `generate_keys -x /secure/path/sparkle-key`, then set the
   GitHub **Actions secret** `SPARKLE_PRIVATE_ED_KEY` to the file's contents.
   Remove the exported file after storing/backing it up securely. Never commit it.
4. Publish through the existing Release or Development workflow. Each passes only
   this specific secret to the reusable packaging workflow. PR builds and normal
   branch builds do not receive the key. Release builds require both settings or
   neither; partial configuration fails the build.

No keys are generated or uploaded by this change. Without this setup, CI continues
producing normal DMGs without active updating. Install the first updater-enabled
build manually; older versions do not have the updater.

The build script uses Sparkle's `generate_appcast` on an isolated directory
containing only the just-built DMG. It checks both the feed and archive signatures
against the public key embedded in the app before exposing `appcast.xml` as a
build artifact. Private keys are passed on stdin, never command-line arguments.
Signed feeds cannot expire into unsigned feeds. Key loss therefore requires a
manual reinstall unless Developer ID signing and Sparkle's key rotation protocol
are introduced separately. Keep the same key for future releases.

## Feeds and version ordering

- Stable: `https://github.com/codyps/spacetree/releases/latest/download/appcast.xml`
- Development: `https://github.com/codyps/spacetree/releases/download/development/appcast.xml`

`GITHUB_REPOSITORY` supplies the owner/repository when building a fork. Feed choice
is embedded at packaging time based on `DISPLAY_VERSION`; there is no automatic
channel switching. Changing channel requires manually installing that channel's
DMG. GitHub hosts both feeds and archives; no separate service or API token is
needed in the app.

Sparkle compares `CFBundleVersion` (`BUILD_NUMBER`), not the display version or Git
hash. CI uses the originating workflow's increasing `github.run_number`; stable
and development remain separate feeds because their counters are independent.
Do not reset these counters or publish older source as a newer build. If replacing
a workflow, preserve/increase its build-number sequence. Local updater builds
must set an appropriate increasing `BUILD_NUMBER` explicitly.

Stable feeds are uploaded to their draft release with the DMG before publication.
The development workflow uploads the versioned DMG before replacing the feed.
Versioned development assets are retained once a feed exists so a previously
fetched feed or open dialog remains usable. Failed builds do not publish feeds.
A failed GitHub upload can leave unused assets but cannot reference an unuploaded
DMG. Do not manually delete DMGs still referenced by clients' cached feeds.

## Build locally

```sh
# Use the public key printed by generate_keys; signing uses your Keychain.
SPARKLE_PUBLIC_ED_KEY='your-public-key' BUILD_NUMBER=123 scripts/build-dmg.sh
# A CI-style environment can instead supply SPARKLE_PRIVATE_ED_KEY.
```

Omit the public key to disable updating in the packaged app. The framework remains
embedded, but no updater instance is created. Check Settings for an explicit
inactive-build message. Existing macOS Gatekeeper, code signing, and Full Disk
Access requirements remain unchanged; Ed25519 archive signing does not notarize
the app.

## Validation

`swift test -c release` covers configuration gating and inactive updater behavior.
`python3 -m unittest discover -s scripts -p 'test_*.py'` covers feed selection,
key validation, and opt-in defaults. `scripts/build-dmg.sh` checks both architecture
slices, embedded framework, packaged signature/resources, and (when configured)
cryptographic feed and archive signatures.

Before first public rollout, install an older updater-enabled build in a writable
Applications directory, publish a newer signed build on the same channel, choose
Check for Updates, then Install and Relaunch. Verify the new About version and
retained scan history. Also check disabled automatic checks, invalid signatures,
and launching from a read-only DMG. These UI/install checks require a running
app and two published versions; passing unit tests alone does not establish them.

Implementation validation on macOS: 86 release-mode Swift tests and 18 Python
release-script tests passed, and actionlint passed. A universal DMG built with an
ephemeral test key passed mount, framework/signature, and signed-feed/archive
verification; modified feeds, modified archives, and a mismatched public key
were rejected. The packaged app launched. Native automation could capture the
window but could not resolve its accessibility surface, so settings interaction
and end-to-end Install and Relaunch remain unverified. No release signing keys
or GitHub settings were provisioned.
