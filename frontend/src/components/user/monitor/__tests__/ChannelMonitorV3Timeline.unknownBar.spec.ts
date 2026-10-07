import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { nextTick } from 'vue'
import type { MonitorHealth, MonitorMatrixBucket, MonitorMetric } from '@/api/channelMonitorV2'
import { isMobileDevice } from '@/utils/device'
import ChannelMonitorV3Timeline from '../ChannelMonitorV3Timeline.vue'

vi.mock('@/utils/device', () => ({
  isMobileDevice: vi.fn(() => false),
}))

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

const originalInnerWidth = window.innerWidth
const mobileDevice = vi.mocked(isMobileDevice)

afterEach(() => {
  document.body.innerHTML = ''
  mobileDevice.mockReturnValue(false)
  Object.defineProperty(window, 'innerWidth', { configurable: true, value: originalInnerWidth })
  vi.restoreAllMocks()
})

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

  it('anchors the mobile edge tooltip arrow to the tapped bar', async () => {
    mobileDevice.mockReturnValue(true)
    Object.defineProperty(window, 'innerWidth', { configurable: true, value: 400 })
    let tooltipMeasurements = 0
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function () {
      if (this.classList.contains('v3-bar-hitbox')) {
        return { left: 350, right: 370, top: 100, bottom: 120, width: 20, height: 20 } as DOMRect
      }
      if (this.classList.contains('v3-timeline-tooltip')) {
        tooltipMeasurements++
        return { left: 104, right: 384, top: 0, bottom: 40, width: 280, height: 40 } as DOMRect
      }
      return { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 } as DOMRect
    })

    const wrapper = mount(ChannelMonitorV3Timeline, {
      props: { countdownSeconds: 0, length: 1, coverage },
    })

    await wrapper.get('.v3-bar-hitbox').trigger('focus')
    for (let i = 0; i < 5; i++) await nextTick()

    const tooltip = document.body.querySelector<HTMLElement>('.v3-timeline-tooltip')
    expect(tooltip?.style.getPropertyValue('--tooltip-x')).toBe('-100%')
    expect(tooltip?.style.getPropertyValue('--tooltip-arrow-left')).toBe('256px')
    expect(tooltipMeasurements).toBeLessThan(5)
    wrapper.unmount()
  })

  it('does not add mobile arrow positioning to the desktop tooltip', async () => {
    mobileDevice.mockReturnValue(false)
    Object.defineProperty(window, 'innerWidth', { configurable: true, value: 400 })
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function () {
      if (this.classList.contains('v3-bar-hitbox')) {
        return { left: 350, right: 370, top: 100, bottom: 120, width: 20, height: 20 } as DOMRect
      }
      return { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 } as DOMRect
    })

    const wrapper = mount(ChannelMonitorV3Timeline, {
      props: { countdownSeconds: 0, length: 1, coverage },
    })

    await wrapper.get('.v3-bar-hitbox').trigger('focus')
    await nextTick()

    const tooltip = document.body.querySelector<HTMLElement>('.v3-timeline-tooltip')
    expect(tooltip?.style.getPropertyValue('--tooltip-x')).toBe('-100%')
    expect(tooltip?.style.getPropertyValue('--tooltip-arrow-left')).toBe('')
    wrapper.unmount()
  })

  it('clears the teleported tooltip when the timeline loses focus', async () => {
    const wrapper = mount(ChannelMonitorV3Timeline, {
      props: { countdownSeconds: 0, length: 1, coverage },
    })

    await wrapper.get('.v3-bar-hitbox').trigger('focus')
    expect(document.body.querySelector('.v3-timeline-tooltip')).not.toBeNull()

    await wrapper.get('.v3-timeline-bars').trigger('mouseleave')
    await new Promise(resolve => setTimeout(resolve, 150))
    expect(document.body.querySelector('.v3-timeline-tooltip')).toBeNull()
    wrapper.unmount()
  })
})
