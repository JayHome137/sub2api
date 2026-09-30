import { describe, expect, it } from 'vitest'
import { createSandboxedHtmlPreview } from '../sandboxedHtmlPreview'

describe('createSandboxedHtmlPreview', () => {
  it('replaces response policies and blocks external requests while retaining inline animation scripts', () => {
    const response = `<!doctype html><html><head>
      <meta http-equiv="Content-Security-Policy" content="default-src *; connect-src *">
    </head><body>
      <script>window.animationReady = true</script>
      <img src="https://example.invalid/art.png">
    </body></html>`

    const preview = createSandboxedHtmlPreview(response)
    const parsed = new DOMParser().parseFromString(preview, 'text/html')
    const policies = parsed.querySelectorAll('meta[http-equiv="Content-Security-Policy"]')

    expect(policies).toHaveLength(1)
    expect(policies[0].content).toContain("default-src 'none'")
    expect(policies[0].content).toContain("connect-src 'none'")
    expect(policies[0].content).toContain("script-src 'unsafe-inline'")
    expect(parsed.querySelector('script')?.textContent).toContain('animationReady')
  })
})
