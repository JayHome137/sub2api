import { describe, expect, it } from 'vitest'
import type { MonitorHealth, MonitorMetric } from '@/api/channelMonitorV2'
import { monitorAvailability, monitorCacheRate } from '../monitorPresentation'

const empty = {
  request_count: 0, rpm: 0, error_rate: 0, cache_rate: 0, cache_rate_denominator: 0,
  ttft: { p50_ms: null }, duration: { p50_ms: null },
} as MonitorMetric
const unknown = { overall: 'unknown', error_rate: 'unknown', cache: 'unknown' } as MonitorHealth

describe('privacy-aware monitor rates', () => {
  it('does not claim 100% availability or 0% cache with no evidence', () => {
    expect(monitorAvailability(empty, unknown)).toBeNull()
    expect(monitorCacheRate(empty, unknown)).toBeNull()
  })
  it('preserves rates with redacted counters and throughput', () => {
    const metric = { ...empty, cache_rate: 0.98, error_rate: 0.02 }
    expect(monitorAvailability(metric, unknown)).toBe(0.98)
    expect(monitorCacheRate(metric, unknown)).toBe(0.98)
  })
  it('distinguishes observed zero rates from missing samples', () => {
    expect(monitorAvailability({ ...empty, error_rate: 1 }, unknown)).toBe(0)
    expect(monitorCacheRate(empty, { ...unknown, cache: 'critical' })).toBe(0)
    expect(monitorAvailability(empty, { ...unknown, error_rate: 'healthy' })).toBe(1)
  })
})
