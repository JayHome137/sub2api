import { describe, expect, it } from 'vitest'
import { ttftHealthLevel } from '../ttftHealth'
describe('configured TTFT health baseline', () => {
  it.each([30000, 50000])('uses T=%s for color and diagnosis', (t) => {
    expect(ttftHealthLevel(t, t)).toBe('normal')
    expect(ttftHealthLevel(t + 1, t)).toBe('warning')
    expect(ttftHealthLevel(2*t - 1, t)).toBe('warning')
    expect(ttftHealthLevel(2*t, t)).toBe('critical')
    expect(ttftHealthLevel(3*t, t)).toBe('critical')
  })
  it('updates when the configured baseline changes', () => {
    expect(ttftHealthLevel(40000,30000)).toBe('warning')
    expect(ttftHealthLevel(40000,50000)).toBe('normal')
  })
  it.each([undefined, null, 0, -1, NaN, Infinity])('handles invalid baseline %s', t => {
    expect(ttftHealthLevel(500,t)).toBe('normal')
    expect(ttftHealthLevel(1000,t)).toBe('critical')
    expect(ttftHealthLevel(null,t)).toBe('normal')
  })
})
