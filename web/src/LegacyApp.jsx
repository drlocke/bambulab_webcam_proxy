import { useEffect, useState } from 'react';
import { withBasePath } from './paths';

const streamName = 'bambu';

export function LegacyApp() {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let active = true;
    const update = async () => {
      try {
        const response = await fetch(withBasePath('/api/paths'), { cache: 'no-store' });
        const body = await response.json();
        const stream = body.items?.find((item) => item.name === streamName);
        if (active) setReady(Boolean(stream?.ready));
      } catch {
        if (active) setReady(false);
      }
    };
    update();
    const timer = window.setInterval(update, 3000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, []);

  return (
    <main className="legacy-shell">
      <header className="legacy-header">
        <div><p className="eyebrow">Bambu Lab camera proxy</p><h1>Live view</h1></div>
        <div className="status" data-ready={ready} role="status"><span aria-hidden="true" />{ready ? 'Live' : 'Connecting'}</div>
      </header>
      <section className="viewer" aria-label="Printer camera stream">
        <iframe src={withBasePath(`/webrtc/${streamName}/?autoplay=true&muted=true&controls=true`)} title="Bambu printer live stream" allow="autoplay; fullscreen; picture-in-picture" />
        {!ready && <div className="waiting">Waiting for camera frames</div>}
      </section>
      <footer className="legacy-footer"><p>WebRTC transport</p><p>Low-latency live video</p></footer>
    </main>
  );
}