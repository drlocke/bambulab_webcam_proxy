# Bambu Lab Webcam Proxy for Windows

Low-latency Bambu printer video for browser applications. The proxy uses the
current Bambu Studio CameraTools or a printer's local RTSP stream, publishes it
through MediaMTX, and exposes WebRTC through nginx.

The included React player is served at <http://127.0.0.1:8090/>. A native React
WHEP example without the MediaMTX iframe is available at
<http://127.0.0.1:8090/native/>.

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
```

WebRTC is intentional. HLS needs independently decodable segments and adds
latency; the Bambu camera can go too long between suitable keyframes, making an
HLS remux unreliable. Direct printer streams are forwarded without transcoding.
Bambu Studio's RTP timestamps are not suitable for browser playback, so that
mode rewrites packet timestamps to a fixed 30 FPS clock. Its original 1920x1080
H.264 bitstream is copied unchanged: there is no video decoding, scaling, or
re-encoding. This preserves Bambu Studio's image quality and GOP structure while
preventing delayed motion and browser frame loss.

## Requirements

- Windows 10 or newer
- Current Bambu Studio with Virtual Camera installed
- Node.js 22.12 or newer, only for building the example app
- PowerShell 5.1 or newer

`scripts/setup.ps1` downloads checksum-pinned MediaMTX and stable nginx builds.
CameraTools is used from `%APPDATA%\BambuStudio\cameratools`; vendor binaries and
camera credentials are not copied into this repository.

## Setup

1. In Bambu Studio, open Live View and enable Virtual Camera once.
2. Run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
   ```

3. Start the proxy with `start_streaming.bat`.
4. Open <http://127.0.0.1:8090/>.

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

BambuStudio obtains temporary TUTK/Agora camera credentials through its closed
network plugin. Current upstream code writes them to CameraTools `url.txt`; Agora
refresh uses a callback pointer into the running BambuStudio process. Therefore,
there is no stable standalone download URL or public authentication endpoint that
this project can safely reproduce.

For reliable cloud streaming, keep Bambu Studio Virtual Camera active. The proxy
automatically consumes its RTP output and never logs the credential URL. The
standalone CameraTools fallback can use the latest `url.txt`, but cloud credentials
may expire and require Bambu Studio to refresh them.

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

Default local endpoints:

| Purpose | URL |
| --- | --- |
| Example application | `http://127.0.0.1:8090/` |
| Native React/WHEP example | `http://127.0.0.1:8090/native/` |
| WebRTC player | `http://127.0.0.1:8090/webrtc/bambu/` |
| WHEP endpoint | `http://127.0.0.1:8090/webrtc/bambu/whep` |
| Service health | `http://127.0.0.1:8090/health` |

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
      style={{ width: '100%', aspectRatio: '16 / 9', border: 0 }}
    />
  );
}
```

For custom controls, connect a browser `RTCPeerConnection` directly to
`/webrtc/bambu/whep` using the WHEP protocol. The included application source is
under `web\src` and its production output is served from `nginx\html`.

Browsers cannot connect directly to printer RTSP/RTP or proprietary Bambu cloud
tunnels. See [Direct browser playback](docs/direct-browser.md) for the native
React example, protocol constraints, credential requirements, and setup guide.

## Configuration

Non-secret defaults are in `config.psd1`. Put machine-specific or secret values
in ignored `config.local.psd1`; keys there override the defaults.

When exposing the service beyond localhost, add TLS and authentication at the
reverse proxy and configure `webrtcAdditionalHosts` in both MediaMTX files with
the server address reachable by browsers. The default configuration deliberately
binds HTTP and control interfaces to loopback only.
