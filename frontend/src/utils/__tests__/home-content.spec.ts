import { describe, expect, it } from 'vitest'
import { sanitizeHomeContentHtml, sanitizeHomeContentUrl } from '../home-content'

describe('home-content', () => {
  it('removes executable and interactive HTML while preserving display content', () => {
    const result = sanitizeHomeContentHtml(`
      <section class="hero" style="color: red">
        <h1>Safe heading</h1>
        <img src="https://cdn.example.com/logo.png" onerror="alert(1)">
        <a href="javascript:alert(2)" onclick="alert(3)">unsafe link</a>
        <script>alert(4)</script>
        <iframe srcdoc="<script>alert(5)</script>"></iframe>
        <form action="https://evil.example"><input name="password"></form>
      </section>
    `)

    const container = document.createElement('div')
    container.innerHTML = result

    expect(container.querySelector('section.hero')?.textContent).toContain('Safe heading')
    expect(container.querySelector('section.hero')?.getAttribute('style')).toBe('color: red')
    expect(container.querySelector('img')?.getAttribute('src')).toBe('https://cdn.example.com/logo.png')
    expect(container.querySelector('img')?.hasAttribute('onerror')).toBe(false)
    expect(container.querySelector('a')?.hasAttribute('href')).toBe(false)
    expect(container.querySelector('a')?.hasAttribute('onclick')).toBe(false)
    expect(container.querySelector('script, iframe, form, input')).toBeNull()
  })

  it('accepts only absolute HTTP(S) iframe URLs', () => {
    expect(sanitizeHomeContentUrl(' https://example.com/welcome?theme=dark ')).toBe(
      'https://example.com/welcome?theme=dark',
    )
    expect(sanitizeHomeContentUrl('HTTP://example.com/welcome')).toBe(
      'http://example.com/welcome',
    )
    expect(sanitizeHomeContentUrl('javascript:alert(1)')).toBe('')
    expect(sanitizeHomeContentUrl('data:text/html,<script>alert(1)</script>')).toBe('')
    expect(sanitizeHomeContentUrl('//example.com/welcome')).toBe('')
    expect(sanitizeHomeContentUrl('/welcome')).toBe('')
  })
})
