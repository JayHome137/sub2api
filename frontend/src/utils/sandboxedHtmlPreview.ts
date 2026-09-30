const previewPolicy = [
  "default-src 'none'",
  "script-src 'unsafe-inline'",
  'img-src data: blob:',
  "style-src 'unsafe-inline' data:",
  'font-src data:',
  'media-src data:',
  "connect-src 'none'",
  "frame-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "navigate-to 'none'",
].join('; ')

export function createSandboxedHtmlPreview(response: string): string {
  if (!response || typeof DOMParser === 'undefined') return ''
  const parsed = new DOMParser().parseFromString(response, 'text/html')
  for (const meta of parsed.querySelectorAll('meta[http-equiv]')) meta.remove()
  const policy = parsed.createElement('meta')
  policy.httpEquiv = 'Content-Security-Policy'
  policy.content = previewPolicy
  parsed.head.prepend(policy)
  return `<!doctype html>${parsed.documentElement.outerHTML}`
}
