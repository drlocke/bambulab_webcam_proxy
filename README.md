# Bambu Lab Webcam Proxy for Windows

Low-latency Bambu printer video for browser applications. Choose between an
anonymous, backwards-compatible single-camera deployment and a session-based
multi-printer console. Both publish through MediaMTX and expose WebRTC through
nginx.

| Mode | Authentication | Sources | Browser experience |
| --- | --- | --- | --- |
| `Legacy` (default) | None | Local RTSP, active Virtual Camera, or existing CameraTools URL | Existing single-camera player at `/` and native WHEP example at `/native/` |
| `Multi` | Bambu account with persistent server session | One cloud CameraTools process per selected online printer | Printer list, single-camera view, and responsive all-camera grid |

The multi-printer setup is documented in
[Multi-printer setup](docs/setup-multi.md). Existing installations remain in
`Legacy` mode unless explicitly reconfigured.

## Architecture

```mermaid
flowchart LR
    A[Bambu printer] --> B{Source}
    B -->|Local RTSP/RTSPS| C[MediaMTX]
    B -->|Bambu Studio RTP| G[FFmpeg packet retiming]
    G -->|Original 1080p30 H.264| C
    B -->|CameraTools H.264| D[FFmpeg]
    D -->|RTSP| C
    C -->|WHEP / WebRTC| E[nginx :8090]
    E --> F[React browser client]
    H[Node multi-printer service] -->|Account API and stream lifecycle| B
    E -->|/api| H
```

WebRTC is intentional. HLS needs independently decodable segments and adds
latency; the Bambu camera can go too long between suitable keyframes, making an
HLS remux unreliable. Direct printer streams are forwarded without transcoding.
Bambu Studio's RTP timestamps are not suitable for browser playback, so that
mode rewrites packet timestamps to a fixed 30 FPS clock. Its original 1920x1080
H.264 bitstream is copied unchanged: there is no video decoding, scaling, or
re-encoding. This preserves Bambu Studio's image quality and GOP structure while
preventing delayed motion and browser frame loss.

CameraTools cloud output has a different timing defect: it delivers an average
of roughly 28 FPS in bursts of about three frames followed by approximately
108 ms gaps. Multi mode applies adaptive packet-copy retiming that spaces those
frames evenly while following wall-clock elapsed time. A fixed 30 FPS clock is
not used there because it runs faster than the actual source and periodically
forces the browser jitter buffer to drop delay and jump forward.

On some Chromium/Windows GPU combinations, direct video-overlay presentation
can briefly flash at H.264 keyframe boundaries even when WebRTC reports no
packet loss, decoder drops, freezes, or reconnects. The included embedded and
native players keep the video in Chromium's normal compositing path with a
near-opaque CSS filter. This is a browser presentation workaround; it does not
change, cache, decode, or re-encode the stream.

## Requirements

- Windows 10 or newer
- Current Bambu Studio with CameraTools installed
- Node.js 22.12 or newer; setup installs a pinned local copy with npm when an
  adequate system installation is unavailable
- PowerShell 5.1 or newer

`scripts/setup.ps1` downloads checksum-pinned Node.js, MediaMTX, and stable nginx
builds as needed. A downloaded Node.js installation remains under `tools\node`
and is used by both the web build and Multi-mode backend without changing the
machine-wide installation.
CameraTools is used from `%APPDATA%\BambuStudio\cameratools`; vendor binaries and
camera credentials are not copied into this repository.

## Legacy Setup

1. In Bambu Studio, open Live View and enable Virtual Camera once.
2. Run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
   ```

3. Start the proxy with `start_streaming.bat`.
4. Open <http://127.0.0.1:8090/>.

To make the selected mode explicit, run this before setup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure.ps1 -Mode Legacy
```

The source is selected in this order:

1. A local printer RTSP/RTSPS URL from `config.local.psd1`
2. An active Bambu Studio Virtual Camera RTP stream
3. CameraTools reading Bambu Studio's `cameratools\url.txt`

### Direct Printer Mode

This is the preferred unattended mode when the printer firmware exposes RTSP or
RTSPS. Copy `config.local.example.psd1` to `config.local.psd1`, then set the
printer IP and LAN access code:

```powershell
@{
    PrinterStreamUrl = 'rtsps://bblp:ACCESS_CODE@PRINTER_IP/streaming/live/1'
}
```

The local file is ignored by Git. Availability and the exact RTSP scheme depend
on the printer model and firmware.

### Bambu Cloud Mode

Bambu's unsupported cloud API can authenticate an account and list its bound
printers. The historically documented TTCode endpoint now returns Bambu error
code `8` (`Resource forbidden`) for independently authenticated clients, even
with the observed slicer headers and a persistent client ID.

`Multi` mode implements account login, bound-printer discovery, TTCode requests,
and per-printer CameraTools publishers. When TTCode returns code `8`, it can use
Bambu Studio's authorized `cameratools\url.txt` descriptor only if the embedded
device ID matches the selected printer. Open that printer's Live View once in
Bambu Studio to refresh the file, then close Live View before starting it here.
CameraTools uses one global Windows mapping, so this fallback supports the one
printer currently cached in `url.txt`; concurrent cloud cameras still require
authorized per-printer tickets. Descriptors remain server-side and are never
logged or returned to the browser.

## Operations

```powershell
.\start_streaming.bat
.\status_streaming.bat
.\stop_streaming.bat
```

Runtime state and logs are under `runtime\` and are ignored by Git. Startup fails
instead of reporting false success when a dependency is missing, a required port
is occupied, nginx configuration is invalid, or a health endpoint is unavailable.
The CameraTools pipeline is supervised and restarted after unexpected exits.
In `Multi` mode, encrypted login sessions survive browser refreshes and service
restarts. Signing out stops that session's active publishers.

`status_streaming.bat` reports every background component with its PID, service
uptime, endpoint health, and stream readiness. If the service is degraded, it
also prints the latest error-log lines. Run `status_streaming.bat -Logs` to show
them even while the service is healthy. The older `check_instances.bat` remains
available as an alias.

Default local endpoints:

| Purpose | URL |
| --- | --- |
| Example application | `http://127.0.0.1:8090/` |
| Native React/WHEP example | `http://127.0.0.1:8090/native/` |
| WebRTC player | `http://127.0.0.1:8090/webrtc/bambu/` |
| WHEP endpoint | `http://127.0.0.1:8090/webrtc/bambu/whep` |
| Service health | `http://127.0.0.1:8090/health` |

### Network access

nginx listens on TCP port `8090` on all network interfaces. MediaMTX control,
RTSP, WebRTC signaling, and the Multi backend remain bound to loopback and are
reached only through nginx. MediaMTX's ICE media listener is the exception: it
listens on UDP and TCP port `8189` so browsers can receive WebRTC media.

To allow connections from any remote address on every Windows network profile,
run these commands once in an elevated PowerShell window:

```powershell
New-NetFirewallRule -DisplayName 'Bambu Webcam HTTP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8090 -RemoteAddress Any -Profile Any
New-NetFirewallRule -DisplayName 'Bambu Webcam WebRTC UDP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 8189 -RemoteAddress Any -Profile Any
New-NetFirewallRule -DisplayName 'Bambu Webcam WebRTC TCP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8189 -RemoteAddress Any -Profile Any
```

These rules are intentionally not restricted by source network. They open the
ports in Windows Firewall, but they do not create router port forwards or alter
VLAN, VPN, cloud-security-group, or perimeter-firewall policies. Those devices
must allow the same traffic separately. Expose `8090` beyond a trusted network
only when an authenticated HTTPS reverse proxy protects it; Legacy mode has no
built-in authentication.

If rules with these names already exist, update them instead of creating
duplicates:

```powershell
Get-NetFirewallRule -DisplayName 'Bambu Webcam HTTP' | Set-NetFirewallRule -Enabled True -Profile Any
Get-NetFirewallRule -DisplayName 'Bambu Webcam HTTP' | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress Any
Get-NetFirewallRule -DisplayName 'Bambu Webcam WebRTC UDP','Bambu Webcam WebRTC TCP' | Set-NetFirewallRule -Enabled True -Profile Any
Get-NetFirewallRule -DisplayName 'Bambu Webcam WebRTC UDP','Bambu Webcam WebRTC TCP' | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress Any
```

Then open `http://SERVER_LAN_IP:8090/`. MediaMTX advertises addresses from the
server's network interfaces automatically. Keep ports `8787`, `8889`, `8554`,
and `9997` blocked; they are internal services, not public entry points.

For access across the internet, do not publish port `8090` as unauthenticated
plain HTTP. Put nginx behind an HTTPS reverse proxy with access control, forward
UDP `8189` (and optionally TCP `8189` as fallback) to this server, and add the
public DNS name or IP to `webrtcAdditionalHosts` in both `mediamtx.yml` and
`mediamtx-studio.yml`. Multi deployments behind HTTPS must also enable
`SecureCookies`; Legacy mode has no application authentication and therefore
requires authentication at the reverse proxy. See
[HTTPS reverse proxy deployment](docs/reverse-proxy.md) for a complete nginx
virtual host, firewall rules, and validation steps.

In `Multi` mode, `/` becomes the account and printer console. The legacy
`/webrtc/bambu/` route remains available only when a legacy source publishes the
`bambu` path.

## React Embedding

### Embedded MediaMTX player

The simplest integration embeds MediaMTX's complete WebRTC player. It owns its
`RTCPeerConnection`, WHEP session, retry behavior, controls, and video element.
Using a relative URL keeps signaling on the application's origin:

```jsx
export function BambuCamera() {
  return (
    <iframe
      src="/webrtc/bambu/?autoplay=true&muted=true&controls=true"
      title="Bambu printer live stream"
      allow="autoplay; fullscreen; picture-in-picture"
      style={{
        width: '100%',
        aspectRatio: '16 / 9',
        border: 0,
        transform: 'translateZ(0)',
        filter: 'opacity(99.999%)',
        backfaceVisibility: 'hidden',
        contain: 'paint',
      }}
    />
  );
}
```

The URL above is the fixed `bambu` stream published by Legacy mode. When the
application is deployed under a base path, prefix the URL accordingly, for
example `/camera-app/webrtc/bambu/`. Multi mode uses opaque, dynamic stream
paths: use the player URL returned or derived from the authenticated stream API
instead of hard-coding `bambu`.

The compositing properties prevent a confirmed once-per-keyframe flash on
affected Chromium/Windows systems. Removing them is useful only as a diagnostic
comparison; it does not select a different player or transport.

### Native RTCPeerConnection player

Use a native player when the application must own the `video` element, custom
controls, connection state, telemetry, retries, or stream switching. This
complete React example gathers an ICE offer, creates a WHEP session, applies the
SDP answer, renders the received track, and deletes the server session during
cleanup:

```jsx
import { useEffect, useRef } from 'react';

function waitForIceGathering(peerConnection) {
  if (peerConnection.iceGatheringState === 'complete') return Promise.resolve();

  return new Promise((resolve) => {
    const handleChange = () => {
      if (peerConnection.iceGatheringState !== 'complete') return;
      peerConnection.removeEventListener('icegatheringstatechange', handleChange);
      resolve();
    };
    peerConnection.addEventListener('icegatheringstatechange', handleChange);
  });
}

export function BambuWhepCamera({
  whepUrl = '/webrtc/bambu/whep',
  controls = true,
}) {
  const videoRef = useRef(null);

  useEffect(() => {
    const abortController = new AbortController();
    const peerConnection = new RTCPeerConnection();
    let sessionUrl = null;

    peerConnection.addTransceiver('video', { direction: 'recvonly' });
    peerConnection.addEventListener('track', (event) => {
      if (!videoRef.current) return;
      videoRef.current.srcObject =
        event.streams[0] ?? new MediaStream([event.track]);
    });

    async function connect() {
      const offer = await peerConnection.createOffer();
      await peerConnection.setLocalDescription(offer);
      await waitForIceGathering(peerConnection);

      const response = await fetch(whepUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/sdp' },
        body: peerConnection.localDescription.sdp,
        signal: abortController.signal,
      });
      if (!response.ok) {
        throw new Error(`WHEP request failed with HTTP ${response.status}`);
      }

      const location = response.headers.get('Location');
      if (location) sessionUrl = new URL(location, window.location.href).toString();
      await peerConnection.setRemoteDescription({
        type: 'answer',
        sdp: await response.text(),
      });
    }

    connect().catch((error) => {
      if (error.name !== 'AbortError') console.error(error);
    });

    return () => {
      abortController.abort();
      if (sessionUrl) {
        fetch(sessionUrl, { method: 'DELETE', keepalive: true }).catch(() => {});
      }
      peerConnection.close();
      if (videoRef.current) videoRef.current.srcObject = null;
    };
  }, [whepUrl]);

  return <video ref={videoRef} autoPlay muted playsInline controls={controls} />;
}
```

For a subpath deployment, pass the prefixed endpoint, for example
`/camera-app/webrtc/bambu/whep`. In Multi mode, pass the authenticated stream
creation response's relative `whepUrl`; do not replace it with the Legacy path.
Production applications should also reconnect after failed or disconnected
peer states, as the included `web/src/NativePlayer.jsx` does.

### Why both players need port 8189

The iframe changes who implements the player, not how media travels. Its
embedded MediaMTX page creates an `RTCPeerConnection` internally. In the native
example, application code creates the same kind of connection directly.
Consequently, both variants require:

| Traffic | Required for iframe | Required for native player | Purpose |
| --- | --- | --- | --- |
| HTTP `8090`, or HTTPS `443` through the reverse proxy | Yes | Yes | Load the page and perform WHEP signaling |
| UDP `8189` from browser to MediaMTX | Yes | Yes | Preferred ICE/WebRTC media transport |
| TCP `8189` from browser to MediaMTX | Recommended | Recommended | ICE fallback when UDP is unavailable |

WHEP `POST`, `PATCH`, and `DELETE` requests can all succeed through nginx while
the video remains on `Connecting`: signaling is then healthy, but ICE cannot
reach `8189`. The HTTP reverse proxy does not carry the media stream. Across
VLANs, VPNs, NAT, or the internet, allow or forward `8189` on every intervening
firewall and advertise a browser-reachable address with
`webrtcAdditionalHosts`. Use a TURN server through `webrtcICEServers2` when no
direct UDP/TCP path can be provided.

Choose the iframe for the smallest, most robust integration. Choose the native
player only when direct React ownership justifies implementing connection
state, retries, cleanup, accessibility, and controls yourself. Neither option
removes the proxy, changes authentication, or avoids the ICE port requirement.
The included application source is under `web\src` and its production output is
served from `nginx\html`.

Browsers cannot connect directly to printer RTSP/RTP or proprietary Bambu cloud
tunnels. See [Direct browser playback](docs/direct-browser.md) for the native
React example, protocol constraints, credential requirements, and setup guide.

## Configuration

Non-secret defaults are in `config.psd1`. Put machine-specific or secret values
in ignored `config.local.psd1`; keys there override the defaults.

Use `scripts\configure.ps1` to create or update that file automatically. The
multi-printer service uses internal port `8787`; only nginx should access it.

For deployment below an existing HTTPS URL prefix, configure the path before
running setup so the frontend is built with matching asset and service URLs:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure.ps1 -Mode Legacy -BasePath /camera-app/
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -BasePath /camera-app/
```

The reverse proxy must strip the prefix when forwarding requests. See
[HTTPS reverse proxy deployment](docs/reverse-proxy.md#subpath) for the complete
nginx configuration.

When exposing the service beyond a trusted LAN, add TLS and authentication at
the reverse proxy. The default configuration keeps all control interfaces bound
to loopback; only nginx HTTP and the WebRTC media port listen on network
interfaces.
