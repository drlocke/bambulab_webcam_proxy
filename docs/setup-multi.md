# Multi-printer setup

Multi mode provides Bambu account login, persistent browser sessions, bound
printer discovery, concurrent streams, and a no-scroll camera overview. Online
printers are listed first. Offline printers remain visible at the end of both
the list and overview.

## Important limitations

- Bambu's account and TTCode APIs are undocumented and can change without
  notice. Real testing currently returns code `8` (`Resource forbidden`) from
  the TTCode endpoint after successful login and printer discovery. Multi mode
  falls back to Bambu Studio's cached descriptor when it belongs to the selected
  printer.
- The cache contains one printer. Open that printer's Live View once in Bambu
  Studio to refresh `%APPDATA%\BambuStudio\cameratools\url.txt`, then close Live
  View before starting the browser stream. Concurrent cloud cameras still need
  authorized per-printer tickets.
- Remote video still uses BambuSource and the ThroughTek libraries installed by
  Bambu Studio. Review their licenses before redistribution or hosted use.
- Agora-only camera sessions are not supported. Multi mode uses TUTK tickets.
- Account login and printer discovery are verified against the real cloud API.
  Ticket parsing and process startup are covered by local tests, but real ticket
  generation is currently blocked by the upstream authorization policy.
- A separate BambuSource and FFmpeg process is used for every active online
  printer. Capacity depends on network bandwidth, ThroughTek relay use, browser
  WebRTC decoding, and the number of printers.

## Requirements

- Windows 10 or newer
- Node.js 22.12 or newer; setup installs a pinned repository-local copy with npm
  when an adequate system installation is unavailable
- Current Bambu Studio with Virtual Camera/CameraTools installed once
- PowerShell 5.1 or newer
- A Bambu account with a password or email-code login

The service does not require Bambu Studio to remain open. The code-`8` fallback
does require Bambu Studio to have refreshed the selected printer's cached camera
descriptor at least once.

## Automated setup

Open PowerShell in the repository and choose the Bambu account region. Common
values are `us`, `eu`, and `cn`; use the region associated with the account.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure.ps1 -Mode Multi -Region eu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Mode Multi
.\start_streaming.bat
```

Open <http://127.0.0.1:8090/> and sign in. The configurator creates the ignored
`config.local.psd1` and generates a random session-encryption secret. Running it
again preserves that secret so existing saved sessions remain decryptable.

Use email-code login when the account requires additional verification. The
password is sent only to the local backend and immediately discarded after the
Bambu login request. It is never stored in the browser or server session.

## HTTPS deployment

The default nginx listener accepts HTTP connections on all network interfaces,
while backend and MediaMTX control ports remain loopback-only. Before exposing
the console beyond a trusted LAN:

1. Put it behind an HTTPS reverse proxy with its own access controls.
2. Restrict direct access to ports `8787`, `8889`, `8554`, and `9997`.
3. Configure MediaMTX `webrtcAdditionalHosts` with the address browsers can
   reach.
4. Allow UDP `8189` and TCP `8189` from browsers to MediaMTX through Windows
  Firewall and every VLAN, VPN, router, NAT, or cloud firewall on the path.
5. Enable secure session cookies:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure.ps1 -Mode Multi -Region eu -SecureCookies
   ```

Do not enable `SecureCookies` while accessing the application directly over
HTTP; browsers will correctly refuse to send that cookie.

See [HTTPS reverse proxy deployment](reverse-proxy.md) for the complete nginx
configuration, WebRTC port requirements, firewall guidance, and validation
steps.

## How sessions work

The browser receives an opaque `bambu_session` cookie with `HttpOnly`,
`SameSite=Strict`, and a 30-day maximum age. Browser JavaScript cannot read it.
The access token and optional refresh token are encrypted with AES-256-GCM in
`runtime\server\sessions.enc`. The encryption key comes from
`MultiSessionSecret`; if no secret was configured, a machine-local key is
generated under `runtime\server\session.key`.

For predictable backups and service migration, keep the generated
`MultiSessionSecret` from `config.local.psd1` secure. Changing or losing it
invalidates saved sessions. Bambu token refresh behavior is unreliable, so an
expired or revoked token requires login again.

Camera tickets and complete `bambu:///` descriptors are never returned to the
browser. Each active descriptor is written only to its ignored
`runtime\streams\<stream-id>\camera.txt` file. Stream and account IDs exposed to
the browser are random opaque values.

## Using the console

- **Printers** lists every printer bound to the account. Select an online
  printer to start its stream and open the full view.
- **All cameras** starts every currently online printer and fits all online and
  offline tiles into the remaining viewport. The grid recalculates when the
  browser is resized.
- **Refresh** requests the current printer state from Bambu Cloud.
- **Sign out** stops every stream owned by the session and deletes the saved
  session.

Camera publishers are shared between the single and overview pages for the same
logged-in session. WHEP clients retry while BambuSource is connecting or a
publisher is restarting.

## Switching back to legacy mode

```powershell
.\stop_streaming.bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure.ps1 -Mode Legacy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Mode Legacy
.\start_streaming.bat
```

No frontend login is shown in Legacy mode. Existing direct RTSP, Bambu Studio
Virtual Camera, CameraTools fallback, `/native/`, batch files, and the `bambu`
MediaMTX path continue to work.

## Troubleshooting

Run `check_instances.bat` first. Logs are separated by responsibility:

| Location | Purpose |
| --- | --- |
| `runtime\logs\server-error.log` | Multi-printer API startup and unexpected server errors |
| `runtime\streams\<id>\camera-source.log` | BambuSource/ThroughTek messages for one printer |
| `runtime\streams\<id>\ffmpeg.log` | H.264 publication errors for one printer |
| `runtime\logs\mediamtx-error.log` | RTSP/WebRTC server errors |
| `nginx\logs\error.log` | Browser proxy and static-file errors |

Common failures:

- **Login rejected:** try email-code login, verify the account region, and check
  whether the account uses a social login without a Bambu password.
- **Printers appear but streams reconnect forever:** verify CameraTools is
  current, the printer is online, and `BambuRegion`, client version, and network
  version match a current Bambu Studio installation. Open this printer's Live
  View once to refresh `url.txt`, close Live View, and stop any orphaned
  `bambu_source.exe`/Virtual Camera process that still owns the global
  `bambu_stream_url` mapping.
- **Session disappears after restart:** keep `MultiSessionSecret` unchanged and
  ensure `runtime\server` is writable.
- **Video works locally but not remotely:** HTTPS and WHEP signaling can be
  healthy while ICE media is blocked. Verify MediaMTX listens on UDP/TCP
  `8189`, globally allow those ports in Windows Firewall, permit them through
  every intervening VLAN/VPN firewall, and configure a browser-reachable
  `webrtcAdditionalHosts` candidate. TCP can be checked with
  `Test-NetConnection`; validate UDP with firewall counters or packet capture.
  Use TURN when no direct path is possible. Never expose the MediaMTX control
  API. The iframe and native React player have identical ICE requirements.
- **Video flashes roughly once per second in Chromium on Windows:** confirm the
  page is using the current built assets. This can be a direct GPU-overlay
  presentation defect at H.264 keyframes, not browser caching or a WebRTC
  reconnect. The included single-camera and overview players apply a CSS
  compositing guard for affected systems.
- **Video repeatedly slows and catches up:** update to the current publisher.
  CameraTools emits variable-rate H.264 frames in short bursts, so assigning a
  fixed 30 FPS timestamp creates periodic jitter-buffer corrections. Multi mode
  now smooths packet timing while tracking the source's real long-term cadence;
  it still copies the original H.264 without re-encoding.