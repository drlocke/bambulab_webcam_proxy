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
.\check_instances.bat
.\stop_streaming.bat
```

Runtime state and logs are under `runtime\` and are ignored by Git. Startup fails
instead of reporting false success when a dependency is missing, a required port
is occupied, nginx configuration is invalid, or a health endpoint is unavailable.
The CameraTools pipeline is supervised and restarted after unexpected exits.
In `Multi` mode, encrypted login sessions survive browser refreshes and service
restarts. Signing out stops that session's active publishers.

Default local endpoints:

| Purpose | URL |
| --- | --- |
| Example application | `http://127.0.0.1:8090/` |
| Native React/WHEP example | `http://127.0.0.1:8090/native/` |
| WebRTC player | `http://127.0.0.1:8090/webrtc/bambu/` |
| WHEP endpoint | `http://127.0.0.1:8090/webrtc/bambu/whep` |
| Service health | `http://127.0.0.1:8090/health` |

In `Multi` mode, `/` becomes the account and printer console. The legacy
`/webrtc/bambu/` route remains available only when a legacy source publishes the
`bambu` path.

## React Embedding

The simplest integration embeds MediaMTX's WebRTC player. Using a relative URL
keeps signaling on the application's origin:

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

The compositing properties prevent a confirmed once-per-keyframe flash on
affected Chromium/Windows systems. Removing them is useful only as a diagnostic
comparison; it does not select a different player or transport.

For custom controls, connect a browser `RTCPeerConnection` directly to
`/webrtc/bambu/whep` using the WHEP protocol. The included application source is
under `web\src` and its production output is served from `nginx\html`.

Browsers cannot connect directly to printer RTSP/RTP or proprietary Bambu cloud
tunnels. See [Direct browser playback](docs/direct-browser.md) for the native
React example, protocol constraints, credential requirements, and setup guide.

## Configuration

Non-secret defaults are in `config.psd1`. Put machine-specific or secret values
in ignored `config.local.psd1`; keys there override the defaults.

Use `scripts\configure.ps1` to create or update that file automatically. The
multi-printer service uses internal port `8787`; only nginx should access it.

When exposing the service beyond localhost, add TLS and authentication at the
reverse proxy and configure `webrtcAdditionalHosts` in both MediaMTX files with
the server address reachable by browsers. The default configuration deliberately
binds HTTP and control interfaces to loopback only.
