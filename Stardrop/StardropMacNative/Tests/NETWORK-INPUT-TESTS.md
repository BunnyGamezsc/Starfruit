# Network and input regressions

Run `bash Tests/run-network-input-regressions.sh` from the native project (macOS Command Line Tools required).

The C fixture includes the actual RunApp.c and invokes its event callback with created CGEvent objects. It checks unrelated versus assigned releases, synthetic-event exclusion, mouse modifiers, Fn and queued-stop lifecycle. It never posts an input event, starts an event tap or launches an application.

The Nexus fixture compiles actual NexusClient.swift and NexusChangelog.swift, intercepts every network request with an ephemeral URLProtocol and uses a temporary UserDefaults suite deleted on completion. API keys are fixture-only strings. Test stubs replace KeychainHelper and the collection backend metadata value type, so these checks do not validate real Keychain access or backend installation. The fixture validates numeric changelog order, collection metadata/string revision parsing, archive mirror JSON, rejected credential URLs and HTTP/GraphQL errors.

All executables are built in a temporary directory and removed by the script. No app bundle, real profile, mod folder, login credential or Accessibility permission is modified.
