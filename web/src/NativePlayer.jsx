import { useCallback, useEffect, useRef, useState } from 'react';

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

export function WhepPlayer({ whepUrl, title, controls = false, onStatus }) {
  const videoRef = useRef(null);

  useEffect(() => {
    let abortController = null;
    let peerConnection = null;
    let sessionUrl = null;
    let disposed = false;
    let retryTimer = null;

    const closeConnection = () => {
      abortController?.abort();
      if (sessionUrl) fetch(sessionUrl, { method: 'DELETE', keepalive: true }).catch(() => {});
      peerConnection?.close();
      peerConnection = null;
      sessionUrl = null;
    };

    const connect = async () => {
      if (disposed) return;
      closeConnection();
      onStatus?.('connecting');
      abortController = new AbortController();
      peerConnection = new RTCPeerConnection();
      peerConnection.addTransceiver('video', { direction: 'recvonly' });
      peerConnection.addEventListener('track', (event) => {
        if (videoRef.current) videoRef.current.srcObject = event.streams[0] ?? new MediaStream([event.track]);
      });
      peerConnection.addEventListener('connectionstatechange', () => {
        if (disposed) return;
        if (peerConnection?.connectionState === 'connected') onStatus?.('live');
        if (['failed', 'disconnected'].includes(peerConnection?.connectionState)) onStatus?.('reconnecting');
      });
      try {
        const offer = await peerConnection.createOffer();
        await peerConnection.setLocalDescription(offer);
        await waitForIceGathering(peerConnection);

        const response = await fetch(whepUrl, {
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
        onStatus?.('reconnecting');
        retryTimer = window.setTimeout(connect, 2000);
      }
    };

    connect();
    return () => {
      disposed = true;
      window.clearTimeout(retryTimer);
      closeConnection();
      if (videoRef.current) videoRef.current.srcObject = null;
    };
  }, [whepUrl, onStatus]);

  return <video ref={videoRef} autoPlay muted playsInline controls={controls} aria-label={title} />;
}

export function NativePlayer() {
  const [status, setStatus] = useState('connecting');
  const handleStatus = useCallback((value) => setStatus(value), []);
  const ready = status === 'live';

  return (
    <main className="legacy-shell">
      <header className="legacy-header">
        <div>
          <p className="eyebrow">Bambu Lab camera proxy</p>
          <h1>Native React view</h1>
        </div>
        <div className="status" data-ready={ready} role="status">
          <span aria-hidden="true" />
          {ready ? 'Live' : status === 'reconnecting' ? 'Reconnecting' : 'Connecting'}
        </div>
      </header>

      <section className="viewer" aria-label="Printer camera stream">
        <WhepPlayer whepUrl={`/webrtc/${streamName}/whep`} title="Bambu printer live stream" controls onStatus={handleStatus} />
        {!ready && <div className="waiting">Waiting for camera frames</div>}
      </section>

      <footer className="legacy-footer">
        <a href="/">Embedded player</a>
        <p>WHEP / RTCPeerConnection</p>
      </footer>
    </main>
  );
}