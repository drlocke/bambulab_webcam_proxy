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
smooths its bursty arrival timestamps while tracking real elapsed time, and
MediaMTX packages it as WebRTC.

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
Its video element uses the same CSS compositing guard as the embedded player to
avoid a confirmed Chromium/Windows direct-overlay flash at H.264 keyframes. The
guard changes only browser presentation and does not alter WHEP signaling or
the decoded frames.

## Embedded player or native player

The main Legacy page embeds MediaMTX's player in an iframe. That page creates
and manages an `RTCPeerConnection` internally. The native example creates the
connection in application code and attaches its incoming track to a
React-managed `video` element. Both use WHEP signaling and the same WebRTC media
transport; native does not mean a direct connection to the printer.

Choose the iframe when standard controls and MediaMTX's retry behavior are
enough. It has the smallest integration and maintenance surface. Choose the
native approach for application-owned controls, connection telemetry, custom
retry behavior, accessibility, or coordinated stream switching. Native clients
must correctly implement SDP offer/answer exchange, WHEP session URL handling,
cleanup, failure states, and retries. A complete reusable example and a
side-by-side comparison are in the README's
[React Embedding](../README.md#react-embedding) section.

The fixed `/webrtc/bambu/` player and `/webrtc/bambu/whep` endpoint apply to the
Legacy `bambu` stream. Multi mode creates opaque stream paths after an
authenticated API request. Use the returned stream URL; never hard-code a
printer ID, source descriptor, or the Legacy path into a Multi client.

## Browser network requirements

For either player, the browser needs two independent paths:

1. HTTP `8090` locally, or HTTPS `443` through the reverse proxy, loads the
  application and carries WHEP signaling.
2. UDP `8189` connects directly to MediaMTX for ICE/WebRTC media. TCP `8189`
  provides the recommended fallback.

The iframe does not tunnel video through HTTPS. Successful page loading and
successful WHEP requests therefore do not prove that media can flow. When a
player remains on `Connecting`, verify the MediaMTX listeners, candidate
address, Windows Firewall, and all VLAN, VPN, router, NAT, and cloud firewall
boundaries. These requirements are the same in Legacy and Multi modes. See
[HTTPS reverse proxy deployment](reverse-proxy.md#firewall-and-nat) for global
Windows rules, routed-network diagnostics, NAT, and TURN guidance.

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

The account and camera-ticket part can be reproduced without Bambu Studio's
network plugin. Bambu's API is undocumented and unsupported, but the following
flow is confirmed by BambuStudio and community traffic analysis:

1. `POST https://api.bambulab.com/v1/user-service/user/login` with either
   `account` plus `password`, or `account` plus a requested verification code.
2. Use the returned access token as `Authorization: Bearer <token>`.
3. `GET /v1/iot-service/api/user/bind` to list printers bound to the account.
   Entries include the device ID and, where available, the LAN access code.
4. Historically, `POST /v1/iot-service/api/user/ttcode` with
  `{"dev_id":"<device-id>"}` returned `ttcode`, `authkey`, and `passwd` for
  TUTK camera authentication.

Current real-account testing returns HTTP 403 with Bambu code `8` (`Resource
forbidden`) at step 4. The result is unchanged by the observed `X-BBL-*` slicer
headers and `X-BBL-Device-ID`, while `/bind` succeeds with the same bearer token.
The endpoint must therefore be treated as restricted, not as a stable public
ticket API. The descriptor details below document the historical contract and
remain useful when credentials come from an authorized source.

The TUTK descriptor consumed by BambuSource has this core form:

```text
bambu:///tutk?uid=<ttcode>&authkey=<authkey>&passwd=<passwd>&region=<region>
```

BambuStudio appends `device`, `net_ver`, `dev_ver`, `cli_id`, and `cli_ver`.
Recent BambuSource builds have rejected descriptors without at least some of
this fingerprint suffix. The API response documented publicly does not explain
how `region` and every suffix value should be selected across all printer and
account regions, so a production implementation must validate this against
captured, redacted descriptors rather than invent values.

This removes the **network plugin** from ticket creation, but it does not remove
the **camera transport** dependency. `BambuSource.dll`/`bambu_source.exe` uses
the ThroughTek Kalay SDK to run IOTC/AVAPI calls such as connection by UID,
camera authentication, stream start, and frame reception. A URL is only a
descriptor for that client; it is not an HTTP, RTSP, or WebSocket media URL.
Replacing BambuSource completely therefore requires a licensed ThroughTek SDK
client or an independently compatible implementation. The normal cloud API
alone cannot deliver the video bytes.

Agora is a separate path used by the go-live/collaborative flow. Its descriptor
contains an app ID, channel, user, and temporary token or license. BambuStudio
passes a native callback pointer to BambuSource so it can refresh an Agora URL
during a session. That callback mechanism cannot be reconstructed as a URL for
a browser and is not needed for the ordinary TUTK path.

Access tokens, TTCode values, LAN access codes, and complete `bambu:///` URLs
must remain server-side. A complete descriptor is effectively a camera secret
and should never be returned to frontend JavaScript or written to application
logs.

## Multi-account server design

One server can support multiple Bambu accounts and printers. The optional Multi
deployment now provides a backend with these responsibilities:

- authenticate an account, including verification-code and 2FA challenge
  states, then store the access token encrypted instead of retaining the
  password;
- list only printers returned by that account's `/bind` request;
- request a fresh TTCode when a stream starts or reconnects;
- build the secret BambuSource descriptor internally;
- run one supervised BambuSource/FFmpeg publisher per active printer, each on a
  unique MediaMTX path;
- return an opaque stream ID and browser-safe WHEP URL, never the source
  descriptor or camera credentials;
- enforce account ownership, per-account concurrency limits, idle shutdown,
  rate limits, and audit logs with secret redaction.

Its external API shape is:

```text
POST   /api/accounts/login
POST   /api/accounts/{accountId}/verification-code
GET    /api/accounts/{accountId}/printers
POST   /api/accounts/{accountId}/printers/{deviceId}/streams
GET    /api/streams/{streamId}
DELETE /api/streams/{streamId}
```

The stream creation response should contain a relative WHEP endpoint such as
`/webrtc/<opaque-stream-id>/whep`. Password entry in a served frontend is
possible, but direct access-token import or verification-code login is safer:
the backend can discard the password immediately, while Bambu's currently
observed refresh-token endpoint is unreliable and may require re-login when the
long-lived access token expires. Social-login-only accounts may first need a
Bambu password configured.

This implementation removes the network plugin and Bambu Studio runtime from
normal Multi-mode operation. Until the ThroughTek transport is independently
replaced, it still requires the installed CameraTools/BambuSource binaries and
their license terms must be reviewed before redistribution or hosted multi-user
use. See [Multi-printer setup](setup-multi.md) for deployment details.

## Upstream WebCodecs prototype

Current BambuStudio source includes `WSAvcCDialogDemo`, an experimental React
component in its new embedded DeviceWeb UI. Its naming, Chinese development
labels, editable URL, detailed counters, and default
`ws://127.0.0.1:9000/live` identify it as a decoder/transport test harness, not
the production cloud camera path.

The page is only the receiving half of a pipeline:

1. It opens a user-supplied WebSocket.
2. It optionally accepts a JSON configuration message containing an H.264 codec
  string and base64 AvcC decoder configuration.
3. Binary messages contain either raw AvcC NAL units or a custom 14-byte header:
  message type, key-frame flag, 64-bit microsecond timestamp, payload length,
  then H.264 data.
4. If configuration was not sent, it attempts to extract SPS and PPS NAL units
  from an early packet and constructs the decoder configuration itself.
5. It creates a browser `VideoDecoder`, submits `EncodedVideoChunk` objects, and
  draws decoded `VideoFrame` objects onto a canvas while reporting bitrate,
  latency, keyframes, malformed packets, and decode errors.

No producer for port `9000` is present in BambuStudio, and the component does
not call the DeviceWeb C++ bridge to request camera data. The actual off-LAN
camera path is TUTK or Agora through BambuSource; printers do not stream their
camera to this WebSocket. The likely purpose is internal development of a
future C++-to-WebView live-view bridge, or manual testing with a separate local
H.264 WebSocket adapter.

It could be reused in this project only by adding a server that converts our
H.264 stream into its custom WebSocket framing. That would duplicate transport,
signaling, buffering, and lifecycle work already handled by WebRTC/WHEP, while
losing WebRTC congestion control and broad media-element integration. It is
useful as a diagnostic low-level decoder or controlled-latency experiment, but
not as the primary player and not as a route around TUTK authentication.