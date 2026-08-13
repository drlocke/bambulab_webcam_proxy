# Direct browser playback

## Result

A browser cannot connect directly to a Bambu printer camera. React does not
change the browser's networking capabilities:

- Browsers do not implement RTSP or RTSPS in `video`, `fetch`, or WebSocket.
- Browser JavaScript cannot open arbitrary TCP or UDP sockets for RTP.
- `bambu:///tutk` and `bambu:///agora` are proprietary Bambu tunnel URLs, not
  browser URL schemes.
- WebCodecs decodes already-delivered video frames; it is not an RTSP, RTP,
  TUTK, or Agora transport.

The proxy therefore remains necessary as a protocol bridge. It does not decode
or re-encode the video. CameraTools obtains the original H.264 stream, FFmpeg
rewrites only its invalid RTP timestamps, and MediaMTX packages it as WebRTC.

## Native React example

Open <http://127.0.0.1:8090/native/> after starting the proxy. This page does
not embed MediaMTX's player. It creates an `RTCPeerConnection`, performs WHEP
signaling with `/webrtc/bambu/whep`, and assigns the received `MediaStream`
directly to a React-managed `video` element.

Setup is identical to the main application:

1. Enable Virtual Camera in Bambu Studio, or configure local printer RTSP.
2. Run `scripts/setup.ps1` once.
3. Run `start_streaming.bat`.
4. Open <http://127.0.0.1:8090/native/>.

The example source is `web/src/NativePlayer.jsx`. It demonstrates the smallest
supported direct React integration while retaining the required local bridge.

## Authentication requirements

### Local printer RTSP

The printer must expose RTSP/RTSPS. The connection requires:

- printer IP address;
- username `bblp`;
- LAN access code;
- stream path `/streaming/live/1`.

These credentials belong in ignored `config.local.psd1`, never in frontend
JavaScript. Even with them, a browser cannot initiate the RTSP connection.

### Bambu cloud camera

Bambu Studio's logged-in proprietary network plugin requests a temporary camera
URL. The active TUTK form contains `uid`, `authkey`, `passwd`, `region`, device
ID, network/plugin version, printer firmware version, client ID, and client
version. Agora-capable devices additionally use channel/user and temporary token
or license data. Refreshing those values requires Bambu Studio's authenticated
network-plugin session and device context.

There is no documented public camera-authentication API or supported browser SDK
for these Bambu tunnel URLs. Putting temporary camera credentials into React
would also expose them to every page script and browser extension. This project
therefore reads credentials only through installed CameraTools and never serves
them over nginx.

## Upstream WebCodecs prototype

Current BambuStudio source includes an experimental React WebCodecs screen whose
default input is `ws://127.0.0.1:9000/live`. It expects a separate bridge to send
AvcC-formatted H.264 frames and SPS/PPS configuration. BambuStudio does not ship
or start that WebSocket endpoint in the tested release, so it is not a direct
printer connection or a usable standalone integration.