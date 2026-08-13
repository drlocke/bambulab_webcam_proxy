import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const configuredBasePath = process.env.VITE_BASE_PATH || '/';
const base = configuredBasePath === '/' ? '/' : `/${configuredBasePath.replace(/^\/+|\/+$/g, '')}/`;

export default defineConfig({
  base,
  plugins: [react()],
  build: {
    outDir: '../nginx/html',
    emptyOutDir: true,
  },
});