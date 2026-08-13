import { useEffect, useState } from 'react';
import { LegacyApp } from './LegacyApp';
import { MultiApp } from './MultiApp';

export function App() {
  const [mode, setMode] = useState('loading');

  useEffect(() => {
    const controller = new AbortController();
    fetch('/api/config', { cache: 'no-store', signal: controller.signal })
      .then((response) => response.ok ? response.json() : null)
      .then((config) => setMode(config?.mode === 'multi' ? 'multi' : 'legacy'))
      .catch((error) => {
        if (error.name !== 'AbortError') setMode('legacy');
      });
    return () => controller.abort();
  }, []);

  if (mode === 'loading') return <div className="boot-screen">Loading</div>;
  return mode === 'multi' ? <MultiApp /> : <LegacyApp />;
}