import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { NativePlayer } from './NativePlayer';
import { isAppPath } from './paths';
import './styles.css';

const Page = isAppPath(window.location.pathname) ? NativePlayer : App;

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <Page />
  </StrictMode>,
);