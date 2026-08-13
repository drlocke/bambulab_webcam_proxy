import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft, Camera, Grid2X2, List, LogOut, RefreshCw, VideoOff, X } from 'lucide-react';
import { withBasePath } from './paths';

async function api(path, options = {}) {
  const response = await fetch(withBasePath(path), {
    ...options,
    headers: options.body ? { 'Content-Type': 'application/json', ...options.headers } : options.headers,
  });
  const body = response.status === 204 ? null : await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body?.error || `Request failed with HTTP ${response.status}`);
  return body;
}

function useBestGrid(itemCount, active) {
  const containerRef = useRef(null);
  const [layout, setLayout] = useState({ columns: 1, rows: 1 });
  useEffect(() => {
    const container = containerRef.current;
    if (!active || !container || itemCount < 1) return undefined;
    const update = () => {
      const { width, height } = container.getBoundingClientRect();
      const gap = 10;
      let best = { columns: 1, rows: itemCount, area: 0 };
      for (let columns = 1; columns <= itemCount; columns += 1) {
        const rows = Math.ceil(itemCount / columns);
        const cellWidth = (width - gap * (columns - 1)) / columns;
        const mediaHeight = Math.max(0, (height - gap * (rows - 1)) / rows - 38);
        const videoWidth = Math.min(cellWidth, mediaHeight * 16 / 9);
        const videoHeight = Math.min(mediaHeight, cellWidth * 9 / 16);
        if (videoWidth * videoHeight > best.area) best = { columns, rows, area: videoWidth * videoHeight };
      }
      setLayout({ columns: best.columns, rows: best.rows });
    };
    const observer = new ResizeObserver(update);
    observer.observe(container);
    update();
    return () => observer.disconnect();
  }, [active, itemCount]);
  return [containerRef, layout];
}

function Login({ onAuthenticated }) {
  const [step, setStep] = useState('credentials');
  const [account, setAccount] = useState('');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');

  const submit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setMessage('');
    try {
      if (step === 'credentials') {
        await api('/api/auth/login', { method: 'POST', body: JSON.stringify({ account, password }) });
        setPassword('');
        setStep('code');
        setMessage('We sent a verification code to your email address.');
      } else {
        const result = await api('/api/auth/code', { method: 'POST', body: JSON.stringify({ account, code }) });
        onAuthenticated(result);
      }
    } catch (error) {
      setMessage(error.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="login-page">
      <section className="login-panel">
        <div className="brand-mark"><Camera size={22} strokeWidth={1.8} /></div>
        <p className="eyebrow">Bambu camera console</p><h1>{step === 'credentials' ? 'Sign in' : 'Check your email'}</h1>
        <form onSubmit={submit}>
          <label>Bambu account<input type="email" autoComplete="username" value={account} onChange={(event) => setAccount(event.target.value)} readOnly={step === 'code'} required /></label>
          {step === 'credentials'
            ? <label>Password<input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} required /></label>
            : <label>Verification code<input type="text" inputMode="numeric" autoComplete="one-time-code" value={code} onChange={(event) => setCode(event.target.value)} autoFocus required /></label>}
          {message && <p className="form-message" role="status">{message}</p>}
          <button className="primary-button" disabled={busy}>{busy ? 'Please wait...' : step === 'credentials' ? 'Continue' : 'Verify and sign in'}</button>
        </form>
        {step === 'code' && <button className="text-button" type="button" disabled={busy} onClick={() => { setStep('credentials'); setCode(''); setMessage(''); }}><ArrowLeft size={16} /> Use different credentials</button>}
      </section>
    </main>
  );
}

function StreamTile({ printer, stream, controls = false }) {
  const failed = stream?.status === 'error';
  const live = stream?.status === 'live';
  const playerUrl = stream?.whepUrl
    ? withBasePath(stream.whepUrl.replace(/\/whep$/, `/?autoplay=true&muted=true&controls=${controls}`))
    : null;
  return (
    <article className="stream-tile" data-offline={!printer.online}>
      <div className="stream-media">
        {printer.online && stream && !failed
          ? <iframe src={playerUrl} title={`${printer.name} live stream`} allow="autoplay; fullscreen; picture-in-picture" />
          : <div className="offline-state"><VideoOff size={24} /><span>{failed ? stream.error : 'Offline'}</span></div>}
        {printer.online && !live && !failed && <div className="tile-waiting">{stream ? 'Connecting' : 'Starting'}</div>}
      </div>
      <div className="stream-label"><strong>{printer.name}</strong><span>{printer.online ? (failed ? 'Unavailable' : live ? 'Live' : 'Connecting') : 'Offline'}</span></div>
    </article>
  );
}

function Dashboard({ account, onLogout }) {
  const [printers, setPrinters] = useState([]);
  const [streams, setStreams] = useState([]);
  const [view, setView] = useState('printers');
  const [selectedId, setSelectedId] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [gridRef, gridLayout] = useBestGrid(printers.length, view === 'all');

  const refresh = useCallback(async () => {
    try {
      const [printerResult, streamResult] = await Promise.all([api('/api/printers'), api('/api/streams')]);
      setPrinters(printerResult.printers);
      setStreams(streamResult.streams);
      setError('');
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    refresh();
    const timer = window.setInterval(refresh, 5_000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const ensureStream = useCallback(async (printer) => {
    let stream = streams.find((item) => item.printerId === printer.id);
    if (!stream && printer.online) {
      stream = await api('/api/streams', { method: 'POST', body: JSON.stringify({ printerId: printer.id }) });
      setStreams((current) => [...current.filter((item) => item.printerId !== printer.id), stream]);
    }
    return stream;
  }, [streams]);

  const openPrinter = async (printer) => {
    if (!printer.online) return;
    try {
      await ensureStream(printer);
      setSelectedId(printer.id);
      setView('single');
    } catch (requestError) {
      setError(requestError.message);
    }
  };

  const openAll = async () => {
    setView('all');
    const results = await Promise.allSettled(printers.filter((printer) => printer.online).map(ensureStream));
    const started = results.filter((result) => result.status === 'fulfilled' && result.value).map((result) => result.value);
    setStreams((current) => [...current.filter((item) => !started.some((next) => next.printerId === item.printerId)), ...started]);
    const failure = results.find((result) => result.status === 'rejected');
    if (failure) setError(failure.reason.message);
  };

  const selectedPrinter = printers.find((printer) => printer.id === selectedId);
  const selectedStream = streams.find((stream) => stream.printerId === selectedId);

  return (
    <main className="console-shell">
      <header className="console-bar">
        <div className="console-brand"><div className="brand-mark"><Camera size={19} /></div><div><strong>Camera console</strong><span>{account}</span></div></div>
        <nav className="view-switcher" aria-label="View">
          <button type="button" data-active={view === 'printers'} onClick={() => setView('printers')} title="Printers"><List size={18} /><span>Printers</span></button>
          <button type="button" data-active={view === 'all'} onClick={openAll} title="All cameras"><Grid2X2 size={18} /><span>All cameras</span></button>
        </nav>
        <div className="bar-actions"><button className="icon-button" type="button" onClick={refresh} title="Refresh printers"><RefreshCw size={18} /></button><button className="icon-button" type="button" onClick={onLogout} title="Sign out"><LogOut size={18} /></button></div>
      </header>
      {error && <div className="error-banner" role="alert">{error}<button type="button" onClick={() => setError('')} title="Dismiss"><X size={16} /></button></div>}
      <section className={`console-content ${view === 'all' ? 'overview-content' : ''}`}>
        {loading && <div className="empty-state">Loading printers</div>}
        {!loading && view === 'printers' && <div className="printer-list">
          <div className="section-heading"><div><p className="eyebrow">Fleet</p><h1>Printers</h1></div><span>{printers.filter((printer) => printer.online).length} online</span></div>
          {printers.length === 0 && <div className="empty-state">No printers are bound to this account.</div>}
          {printers.map((printer) => <button className="printer-row" data-offline={!printer.online} type="button" key={printer.id} onClick={() => openPrinter(printer)} disabled={!printer.online}><span className="printer-icon">{printer.online ? <Camera size={21} /> : <VideoOff size={21} />}</span><span className="printer-copy"><strong>{printer.name}</strong><span>{printer.model || 'Bambu Lab printer'}</span></span><span className="printer-state">{printer.online ? 'Online' : 'Offline'}</span></button>)}
        </div>}
        {!loading && view === 'all' && <div ref={gridRef} className="stream-grid" style={{ gridTemplateColumns: `repeat(${gridLayout.columns}, minmax(0, 1fr))`, gridTemplateRows: `repeat(${gridLayout.rows}, minmax(0, 1fr))` }}>{printers.map((printer) => <StreamTile key={printer.id} printer={printer} stream={streams.find((item) => item.printerId === printer.id)} />)}</div>}
        {!loading && view === 'single' && selectedPrinter && <div className="single-view"><button className="back-button" type="button" onClick={() => setView('printers')}><List size={17} /> Printers</button><StreamTile printer={selectedPrinter} stream={selectedStream} controls /></div>}
      </section>
    </main>
  );
}

export function MultiApp() {
  const [session, setSession] = useState(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    api('/api/session').then(setSession).catch(() => setSession({ authenticated: false })).finally(() => setLoading(false));
  }, []);
  const logout = async () => {
    await api('/api/session', { method: 'DELETE' });
    setSession({ authenticated: false });
  };
  if (loading) return <div className="boot-screen">Loading</div>;
  if (!session?.authenticated) return <Login onAuthenticated={setSession} />;
  return <Dashboard account={session.account} onLogout={logout} />;
}