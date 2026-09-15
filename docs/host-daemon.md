# Host Daemon shutdown client

ScreamBar uses the Host Daemon `/api/v1` HTTPS API to shut down the configured WOL
machine. Windows and Linux expose the same API. The client uses Foundation,
Security and CryptoKit already provided by macOS; no additional command-line
client, SSH, SMB or remote Windows RPC tool is involved.

## Connect the agent

Install and start Host Daemon on the PC. The Windows installer automatically creates
**`C:\Program Files\HostDaemon\screambar-pairing.json`**, at the installation root
next to `bin` (or under your chosen installation directory). Copy this file to the
Mac and import it in ScreamBar. No PowerShell export is required; Windows may request
administrator approval to access the file.

The file contains the certificate, daemon UUID, public-key fingerprint, configured
port and a **reusable machine authorization with no time limit**. It survives daemon
restarts and upgrades and can associate several clients. Each import receives its
own client ID and access key; the JSON is not a shared API bearer key. Keep it private:
anyone with a copy can authorize another client with its fixed scopes. Existing
paired clients do not need to reimport it after an upgrade. TLS certificate validity
is checked separately from the machine authorization.

On Linux, `sudo hostctl pairing export --scope daemon.read --scope operations.read
--scope power.shutdown --scope power.cancel` returns the same reusable bundle.
The optional `pairing create` command still returns a single-use enrollment valid
for 600 seconds. Public `export-trust` alone does not create a client key.

In ScreamBar:

1. Enable **Wake on LAN** and enter the machine's MAC address and **host IPv4/prefix**,
   for example `10.2.10.247/16`. A subnet such as `10.2.0.0/16` has no individual
   shutdown target.
2. Under **Shutdown agent**, select **Import agent…** and import or paste the JSON.
3. Use **Check** to verify the API connection and power-module availability.
4. When the host is online, Status shows **Shutdown**. A verified agent response
   also establishes reachability if the machine blocks ICMP.

Default HTTPS port is 47831, but ScreamBar uses the port from the imported bundle.
The Windows installer's firewall rule must permit the Mac's connection. Allow
ScreamBar local-network access if macOS requests it; the app bundle includes the
[Apple local-network usage description](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The agent's self-signed TLS identity is checked against the imported public-key
pin, signed daemon identity, validity period and server-certificate policy. This
supports LAN/VPN addresses absent from the certificate's hostname list. No global
certificate trust setting is changed, and redirects are rejected. A replaced or
expired certificate produces an explicit error.

## Shutdown and cancellation

**Shutdown** reads the verified daemon instance and requests a 3-second delay.
The UI shows the agent's countdown and offers **Cancel shutdown** while the API
reports the operation cancellable. Once native OS dispatch starts, cancellation
may be too late. OS acceptance does not prove physical power-off.

In Scream and Direct Routing, closing the menu stops ordinary reachability polling.
OFF and SteelSeries Omni keep it active so the main menu bar icon can show PC status.
Closing the menu never cancels an accepted shutdown. Active operations continue to
be followed using their original
host, daemon instance, request UUID, operation UUID and principal. A public recovery
record is written before sending the mutation and retained under
`~/Library/Application Support/ScreamBar/daemon-pending-action.json`.

OS acceptance keeps **Shutting down…** and blocks further shutdown requests across
menu closure and app restarts. A lost connection during shutdown does not clear
this state or offer **Clear result**. Once the host is offline, **Send Magic Packet**
remains available without discarding the accepted shutdown record. The block is
released only after authenticated status confirms a new agent instance that is not
stopping; module availability is then checked before offering **Shutdown** again.
An agent instance change is not proof of a physical reboot. A confirmed cancellation
or failure releases an operation normally.

Before OS acceptance has been observed, a lost response or interrupted connection
is shown as an unknown result. The client never automatically resubmits a shutdown
or substitutes a new daemon instance. It reads the original operation when its ID
is known, otherwise retaining the uncertainty. **Clear result** dismisses this
unknown record and does not cancel an already-issued shutdown.

An offline machine retains **Send Magic Packet**. Existing USB triggers and
keyboard shortcuts continue to perform WOL/audio actions; they do not initiate
shutdown. Accepted/pending shutdowns remain visible even if WOL is disabled in
Settings. Trust/key replacement is blocked while an operation is pending.

Sending WOL only wakes the machine; automatic agent checks read its status and
module availability without requesting shutdown. A connectivity error clears when
the agent responds again. Completed result messages clear on the next menu opening
or WOL send; pending and accepted shutdown records are retained.

## Per-client keys and existing installations

Pairing is required by the daemon's new-installation default. Existing explicit
`security.require_pairing: false` settings are preserved by upgrades. To activate
required keys on an older installation, set that field to `true` in its local
`config.json` and restart the daemon. Public `export-trust` bundles support only
optional anonymous access and do not issue client credentials.

Import the installer's `screambar-pairing.json` with **Import trust or pairing…**.
ScreamBar exchanges its reusable authorization for its own bearer key and stores
the key in the macOS Keychain, scoped to daemon UUID, host, port and public-key pin.
The enrollment secret and client key are not written to app preferences or recovery
records. Importing again creates a new daemon client and replaces the local key;
the previous daemon client is not automatically revoked.

A revoked/invalid supplied key is rejected; the client does not silently retry as
anonymous. **Forget** removes the current connection's locally stored key and public
trust. `hostctl clients revoke <client-id>` revokes a specific client on the PC.
A holder of the reusable JSON can pair again, so `hostctl pairing revoke` separately
invalidates all copies of the machine authorization; existing client keys remain
valid. Setup preserves that revocation. An administrator can explicitly replace it
with `hostctl pairing rotate --scope ...`, then rerun setup to refresh the file.

## Validation and limits

The client was tested against the sibling daemon's non-destructive backend using
real Swift URLSession HTTPS, IPv4/IPv6 transport, certificate pin validation,
pairing/Keychain, shutdown scheduling, operation reads and cancellation. Transport
checks cover redirects, oversized/chunked responses, resource timeout, independent
request cancellation and invalid credentials without anonymous retry. Service
checks cover double clicks, configuration changes, app/menu lifecycle, persisted
recovery and unknown outcomes. Existing WOL and settings migration tests are run.

No real Windows/Linux shutdown was sent during client validation. The app's WOL
settings currently select IPv4 targets; the native HTTPS layer also supports IPv6.
The bundle is built with the repository's existing ad-hoc signing process.
