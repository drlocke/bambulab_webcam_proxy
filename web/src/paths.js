const basePath = import.meta.env.BASE_URL === '/' ? '' : import.meta.env.BASE_URL.replace(/\/$/, '');

export function withBasePath(path) {
  return `${basePath}/${path.replace(/^\//, '')}`;
}

export function isAppPath(path) {
  return path === withBasePath('/native') || path.startsWith(`${withBasePath('/native')}/`);
}