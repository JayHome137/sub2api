import { mount } from '@vue/test-utils'
import { describe, expect, it, vi } from 'vitest'
import type { MonitorHealth, MonitorMatrixBucket, MonitorMetric } from '@/api/channelMonitorV2'
import ChannelMonitorV3Timeline from '../ChannelMonitorV3Timeline.vue'

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({ t: (key: string) => key, locale: { value: 'zh-CN' } }),
  }
})

function metrics(errorRate: number): MonitorMetric {
  return {
    success_requests: 0,
    error_requests: 0,
    request_count: 0,
    token_count: 0,
    rpm: 0,
    tpm: 0,
    error_rate: errorRate,
    cache_rate: 0,
    cache_rate_numerator: 0,
    cache_rate_denominator: 0,
    ttft: { sample_count: 0, p50_ms: null, p95_ms: null, avg_ms: null },
    duration: { sample_count: 0, p50_ms: null, p95_ms: null, avg_ms: null },
  }
}

function health(overall: MonitorHealth['overall']): MonitorHealth {
  return {
    overall,
    error_rate: overall,
    ttft: overall,
    cache: overall,
    minimum_sample: 50,
  }
}

function bucket(overall: MonitorHealth['overall'], errorRate: number, start: string): MonitorMatrixBucket {
  return {
    bucket_start: start,
    metrics: metrics(errorRate),
    health: health(overall),
  }
}

const coverage = {
  requested_start: '2026-09-11T12:00:00Z', requested_end: '2026-09-11T12:20:00Z',
  coverage_start: '2026-09-11T12:00:00Z', data_through: '2026-09-11T12:19:00Z',
  computed_at: '2026-09-11T12:19:00Z', aggregation_lag_seconds: 0,
  coverage_complete: true, bucket_seconds: 300,
}

describe('ChannelMonitorV3Timeline unknown bars', () => {
  it('paints insufficient-sample bars gray instead of availability black', () => {
    const wrapper = mount(ChannelMonitorV3Timeline, {
      props: {
        buckets: [bucket('unknown', 1, '2026-09-11T12:00:00Z')],
        countdownSeconds: 0,
        length: 1,
        coverage,
      },
    })
    const bar = wrapper.get('.v3-soft-glass-bar')
    expect(bar.classes()).toContain('bg-gray-300')
    expect(bar.classes()).not.toContain('bg-gray-950')
  })

  it('shows true low availability in red in both themes', () => {
    const wrapper = mount(ChannelMonitorV3Timeline, {
      props: {
        buckets: [bucket('critical', 0.8, '2026-09-11T12:00:00Z')],
        countdownSeconds: 0,
        length: 1,
        coverage,
      },
    })
    const bar = wrapper.get('.v3-soft-glass-bar')
    expect(bar.classes()).toContain('bg-red-500')
    expect(bar.classes()).toContain('dark:bg-red-400')
  })

  it('preserves leading, internal and trailing gaps at their real timestamps', () => {
    const wrapper = mount(ChannelMonitorV3Timeline, {
      props: {
        buckets: [bucket('healthy', 0, '2026-09-11T12:05:00Z'), bucket('critical', 0.8, '2026-09-11T11:55:00Z')],
        countdownSeconds: 0, length: 4, coverage,
      },
    })
    const bars = wrapper.findAll('.v3-soft-glass-bar')
    expect(bars).toHaveLength(4)
    expect(bars.map(bar => bar.classes().includes('bg-gray-300'))).toEqual([true, false, true, true])
    expect(bars[1]!.classes()).toContain('bg-emerald-600')
  })
})
