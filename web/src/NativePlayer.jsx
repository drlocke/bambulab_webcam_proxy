import { useEffect, useRef, useState } from 'react';

const streamName = 'bambu';

function waitForIceGathering(peerConnection) {
  if (peerConnection.iceGatheringState === 'complete') return Promise.resolve();

  return new Promise((resolve) => {
    const handleStateChange = () => {
      if (peerConnection.iceGatheringState !== 'complete') return;
      peerConnection.removeEventListener('icegatheringstatechange', handleStateChange);
      resolve();
    };
    peerConnection.addEventListener('icegatheringstatechange', handleStateChange);
  });
}

export function NativePlayer() {
  const videoRef = useRef(null);
  const [status, setStatus] = useState('Connecting');
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const abortController = new AbortController();
    const peerConnection = new RTCPeerConnection();
    let sessionUrl = null;
    let disposed = false;

    peerConnection.addTransceiver('video', { direction: 'recvonly' });
    peerConnection.addEventListener('track', (event) => {
      if (!videoRef.current) return;
      videoRef.current.srcObject = event.streams[0] ?? new MediaStream([event.track]);
    });
    peerConnection.addEventListener('connectionstatechange', () => {
      if (disposed) return;
      if (peerConnection.connectionState === 'connected') {
        setReady(true);
        setStatus('Live');
      } else if (['failed', 'disconnected'].includes(peerConnection.connectionState)) {
        setReady(false);
        setStatus('Disconnected');
      }
    });

    const connect = async () => {
      try {
        const offer = await peerConnection.createOffer();
        await peerConnection.setLocalDescription(offer);
        await waitForIceGathering(peerConnection);

        const response = await fetch(`/webrtc/${streamName}/whep`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/sdp' },
          body: peerConnection.localDescription.sdp,
          signal: abortController.signal,
        });
        if (!response.ok) throw new Error(`WHEP request failed with HTTP ${response.status}`);

        const location = response.headers.get('Location');
        if (location) sessionUrl = new URL(location, window.location.href).toString();
        const answer = await response.text();
        await peerConnection.setRemoteDescription({ type: 'answer', sdp: answer });
      } catch (error) {
        if (disposed || error.name === 'AbortError') return;
        setReady(false);
        setStatus('Connection failed');
        console.error(error);
      }
    };

    connect();
    return () => {
      disposed = true;
      abortController.abort();
      if (sessionUrl) fetch(sessionUrl, { method: 'DELETE', keepalive: true }).catch(() => {});
      peerConnection.close();
    };
  }, []);

  return (
    <main>
      <header>
        <div>
          <p className="eyebrow">Bambu Lab camera proxy</p>
          <h1>Native React view</h1>
        </div>
        <div className="status" data-ready={ready} role="status">
          <span aria-hidden="true" />
          {status}
        </div>
      </header>

      <section className="viewer" aria-label="Printer camera stream">
        <video ref={videoRef} autoPlay muted playsInline controls />
        {!ready && <div className="waiting">Waiting for camera frames</div>}
      </section>

      <footer>
        <a href="/">Embedded player</a>
        <p>WHEP / RTCPeerConnection</p>
      </footer>
    </main>
  );
}