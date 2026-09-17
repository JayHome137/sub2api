import { defineComponent, h } from 'vue'
import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { MonitorMatrixRow, MonitorSnapshot } from '@/api/channelMonitorV2'

const getMatrix = vi.fn()
const getSnapshot = vi.fn()

vi.mock('@/api/channelMonitorV2', () => ({
  getMatrix: (...args: unknown[]) => getMatrix(...args),
  getSnapshot: (...args: unknown[]) => getSnapshot(...args),
}))
vi.mock('@/api/groups', () => ({
  default: {
    getAvailable: vi.fn().mockResolvedValue([]),
    getUserGroupRates: vi.fn().mockResolvedValue({}),
  },
}))
vi.mock('@/stores/app', () => ({
  useAppStore: () => ({ showError: vi.fn() }),
}))
vi.mock('@/components/layout/AppLayout.vue', () => ({
  default: { template: '<div><slot /></div>' },
}))
vi.mock('vue-i18n', async (importOriginal) => {
  const actual = await importOriginal<typeof import('vue-i18n')>()
  return {
    ...actual,
    useI18n: () => ({ t: (key: string) => key, locale: { value: 'zh-CN' } }),
  }
})

import ChannelStatusV3View from '../ChannelStatusV3View.vue'

enableAutoUnmount(afterEach)
afterEach(() => vi.useRealTimers())

function coverage() {
  return {
    requested_start: '2026-09-11T00:00:00Z',
    coverage_start: '2026-09-11T00:00:00Z',
    data_through: '2026-09-11T12:00:00Z',
    computed_at: '2026-09-11T12:00:00Z',
    aggregation_lag_seconds: 0,
    coverage_complete: true,
    bucket_seconds: 300,
  }
}

function metrics() {
  return {
    success_requests: 10,
    error_requests: 0,
    request_count: 10,
    token_count: 100,
    rpm: 1,
    tpm: 10,
    error_rate: 0,
    cache_rate: 0.2,
    cache_rate_numerator: 2,
    cache_rate_denominator: 10,
    ttft: { sample_count: 10, p50_ms: 100, p95_ms: 200, avg_ms: 120 },
    duration: { sample_count: 10, p50_ms: 300, p95_ms: 400, avg_ms: 320 },
  }
}

function health() {
  return {
    overall: 'healthy' as const,
    error_rate: 'healthy' as const,
    ttft: 'healthy' as const,
    cache: 'healthy' as const,
    minimum_sample: 5,
  }
}

function row(platform: string, groupId: number, groupName: string): MonitorMatrixRow {
  return {
    platform,
    group_id: groupId,
    group_name: groupName,
    metrics: metrics(),
    health: health(),
    buckets: [{ bucket_start: '2026-09-11T12:00:00Z', metrics: metrics(), health: health() }],
  }
}

const snapshot: MonitorSnapshot = {
  config: {
    version: 1,
    enabled: true,
    refresh_interval_seconds: 60,
    platforms: [],
    group_ids: [],
    health_thresholds: {
      minimum_sample: 5,
      warning_error_rate: 0.1,
      critical_error_rate: 0.3,
      target_ttft_ms: 400,
      warning_ttft_ms: 800,
      critical_ttft_ms: 1500,
      warning_cache_rate: 0.2,
      critical_cache_rate: 0.05,
      error_weight: 0.5,
      ttft_weight: 0.3,
      cache_weight: 0.2,
    },
  },
  coverage: coverage(),
  metrics: metrics(),
  health: health(),
  trend: [],
}

describe('ChannelStatusV3View platform grouping', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getSnapshot.mockResolvedValue(snapshot)
    getMatrix.mockResolvedValue({
      coverage: coverage(),
      group_by: 'platform_group',
      items: [
        row('openai', 2, 'Codex'),
        row('gemini', 9, 'Gemini'),
        row('openai', 1, 'GPT'),
      ],
    })
  })

  it('renders one section per platform instead of a flat card grid', async () => {
    const wrapper = mount(ChannelStatusV3View, {
      global: {
        stubs: {
          AppLayout: { template: '<div><slot /></div>' },
          Icon: true,
          EmptyState: true,
          ChannelMonitorV3Card: defineComponent({
            name: 'ChannelMonitorV3Card',
            props: ['row'],
            setup: (props) => () => h('div', { 'data-testid': `card-${props.row.group_id}` }, props.row.group_name),
          }),
        },
      },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="channel-status-platform-openai"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="channel-status-platform-gemini"]').exists()).toBe(true)
    const openaiCards = wrapper.get('[data-testid="channel-status-platform-openai"]').findAll('[data-testid^="card-"]')
    expect(openaiCards.map((card) => card.text())).toEqual(['GPT', 'Codex'])
  })

  function mountView() {
    return mount(ChannelStatusV3View, {
      global: {
        stubs: {
          AppLayout: { template: '<div><slot /></div>' },
          Icon: true,
          EmptyState: true,
          ChannelMonitorV3Card: defineComponent({
            name: 'ChannelMonitorV3Card',
            props: ['row'],
            setup: (props) => () => h('div', { 'data-testid': `card-${props.row.group_id}` }, props.row.group_name),
          }),
        },
      },
    })
  }

  function mockRangeRows() {
    getMatrix.mockImplementation(async (filter) => ({
      coverage: coverage(), group_by: 'platform_group',
      items: [row('openai', 1, filter.range)],
    }))
  }

  it('prefetches once and immediately reuses fresh ranges without more requests', async () => {
    vi.useFakeTimers()
    mockRangeRows()
    const wrapper = mountView()
    await flushPromises()
    await vi.advanceTimersByTimeAsync(501)
    expect(getMatrix).toHaveBeenCalledTimes(4)
    for (const range of ['24h', '7d', '30d', '90m']) {
      await wrapper.findAll('button').find(button => button.text() === `channelMonitorV3.ranges.${range}`)!.trigger('click')
      await flushPromises()
      expect(wrapper.get('[data-testid="card-1"]').text()).toBe(range)
    }
    expect(getMatrix).toHaveBeenCalledTimes(4)
    expect(getSnapshot).toHaveBeenCalledTimes(4)
  })

  it('refreshes expired range data instead of treating cached values as live forever', async () => {
    vi.useFakeTimers()
    mockRangeRows()
    const wrapper = mountView()
    await flushPromises()
    await vi.advanceTimersByTimeAsync(501)
    vi.setSystemTime(Date.now() + 61000)
    await wrapper.findAll('button').find(button => button.text() === 'channelMonitorV3.ranges.24h')!.trigger('click')
    await flushPromises()
    expect(getMatrix).toHaveBeenCalledTimes(5)
    expect(wrapper.get('[data-testid="card-1"]').text()).toBe('24h')
  })

  it('deduplicates a pending prefetch and never displays a late response for another range', async () => {
    vi.useFakeTimers()
    mockRangeRows()
    let resolve24!: (value: unknown) => void
    const normal = getMatrix.getMockImplementation()!
    getMatrix.mockImplementation((filter, ...args) => filter.range === '24h'
      ? new Promise(resolve => { resolve24 = resolve }) : normal(filter, ...args))
    const wrapper = mountView()
    await flushPromises()
    await vi.advanceTimersByTimeAsync(501)
    await wrapper.findAll('button').find(button => button.text() === 'channelMonitorV3.ranges.24h')!.trigger('click')
    expect(getMatrix.mock.calls.filter(([filter]) => filter.range === '24h')).toHaveLength(1)
    expect(wrapper.find('[data-testid="card-1"]').exists()).toBe(false)
    await wrapper.findAll('button').find(button => button.text() === 'channelMonitorV3.ranges.7d')!.trigger('click')
    await flushPromises()
    resolve24({ coverage: coverage(), items: [row('openai', 1, '24h')] })
    await flushPromises()
    expect(wrapper.get('[data-testid="card-1"]').text()).toBe('7d')
  })

  it('packs consecutive single-group platforms onto one row with their own headings', async () => {
    getMatrix.mockResolvedValue({
      coverage: coverage(),
      group_by: 'platform_group',
      items: [
        row('openai', 1, 'GPT'),
        row('openai', 2, 'Codex'),
        row('anthropic', 5, 'kiro'),
        row('grok', 6, 'Grok'),
        row('gemini', 9, 'Gemini A'),
        row('gemini', 10, 'Gemini B'),
      ],
    })
    const wrapper = mountView()
    await flushPromises()
    expect(wrapper.get('[data-testid="channel-status-compact-platforms"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="channel-status-platform-anthropic"]').find('h2').exists()).toBe(true)
    expect(wrapper.get('[data-testid="channel-status-platform-grok"]').find('h2').exists()).toBe(true)
    const compact = wrapper.get('[data-testid="channel-status-compact-platforms"]')
    expect(compact.find('[data-testid="card-5"]').text()).toBe('kiro')
    expect(compact.find('[data-testid="card-6"]').text()).toBe('Grok')
  })

  it('does not let a later singleton fill a previous multi-group row', async () => {
    getMatrix.mockResolvedValue({
      coverage: coverage(),
      group_by: 'platform_group',
      items: [
        row('kimi', 11, 'Kimi'),
        row('kimi', 12, 'Kimi B300'),
        row('zhipu', 13, 'GLM'),
      ],
    })
    const wrapper = mountView()
    await flushPromises()
    const kimiCards = wrapper.get('[data-testid="channel-status-platform-kimi"]').findAll('[data-testid^="card-"]')
    expect(kimiCards.map((card) => card.text())).toEqual(['Kimi', 'Kimi B300'])
    expect(wrapper.get('[data-testid="channel-status-platform-kimi"]').find('[data-testid="card-13"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="channel-status-platform-zhipu"]').find('[data-testid="card-13"]').text()).toBe('GLM')
  })
})
