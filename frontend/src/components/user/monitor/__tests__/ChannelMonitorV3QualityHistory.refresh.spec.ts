import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { getQualityEvents } = vi.hoisted(() => ({
  getQualityEvents: vi.fn(),
}))

vi.mock('@/api/channelMonitorV2', () => ({
  getQualityEvents: (...args: unknown[]) => getQualityEvents(...args),
}))
vi.mock('vue-i18n', async (importOriginal) => {
  const actual = await importOriginal<typeof import('vue-i18n')>()
  return {
    ...actual,
    useI18n: () => ({ t: (key: string) => key, locale: { value: 'zh-CN' } }),
  }
})

import ChannelMonitorV3QualityHistory from '../ChannelMonitorV3QualityHistory.vue'

enableAutoUnmount(afterEach)
afterEach(() => vi.restoreAllMocks())

describe('ChannelMonitorV3QualityHistory refresh', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getQualityEvents.mockResolvedValue([])
  })

  it('renders a fixed 20-slot status strip and loads only the visible history', async () => {
    const wrapper = mount(ChannelMonitorV3QualityHistory, {
      props: { groupId: 17, enabled: true, refreshRevision: 1 },
    })
    await flushPromises()

    expect(getQualityEvents).toHaveBeenCalledWith(17, 18)
    expect(wrapper.findAll('[data-testid^="quality-history-slot-"]')).toHaveLength(18)
    expect(wrapper.find('[data-testid="quality-history-slot-0"]').classes()).toContain('is-unknown')
    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryStatusTitle')
  })

  it('keeps a compact disabled state instead of leaving an empty card area', async () => {
    const wrapper = mount(ChannelMonitorV3QualityHistory, {
      props: { groupId: 17, enabled: false },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="channel-quality-history"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryStatusDisabled')
    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryFooterDisabled')
    expect(wrapper.findAll('.quality-history-slot.is-empty')).toHaveLength(18)
    expect(getQualityEvents).not.toHaveBeenCalled()
  })

  it('shows waiting state when the group is enabled without completed checks', async () => {
    const wrapper = mount(ChannelMonitorV3QualityHistory, {
      props: { groupId: 17, enabled: true },
    })
    await flushPromises()

    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryStatusWaiting')
    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryFooterWaiting')
  })

  it('maps the newest API event to the right edge and exposes only summary data', async () => {
    getQualityEvents.mockResolvedValue([
      {
        id: 82,
        group_id: 17,
        account_id: 3,
        model_id: 'gpt-5',
        status: 'degraded',
        quality_mode: 'candy',
        error_message: 'hidden from the status summary',
        latency_ms: 9130,
        cron_expression: '*/30 * * * *',
        created_at: '2026-10-02T04:02:00Z',
      },
      {
        id: 81,
        group_id: 17,
        account_id: 3,
        model_id: 'gpt-5',
        status: 'success',
        quality_mode: 'pelican',
        error_message: '',
        latency_ms: 8200,
        cron_expression: '*/30 * * * *',
        created_at: '2026-10-02T04:01:00Z',
      },
    ])
    const wrapper = mount(ChannelMonitorV3QualityHistory, { props: { groupId: 17, enabled: true } })
    await flushPromises()

    const slots = wrapper.findAll('[data-testid^="quality-history-slot-"]')
    expect(slots[16].classes()).toContain('is-pass')
    expect(slots[17].classes()).toContain('is-degraded')
    expect(wrapper.find('[data-testid="quality-history-model"]').text()).toBe('gpt-5')
    expect((slots[17].element as HTMLElement).className).toContain('quality-history-slot')
    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryStatusDegraded')
    expect(wrapper.text()).toContain('30 min')
    expect(wrapper.text()).not.toContain('hidden from the status summary')
    await slots[17].trigger('mouseenter')
    expect(wrapper.find('[data-testid="quality-history-tooltip"]').text()).toContain('9.13s')
    expect(wrapper.find('[data-testid="quality-history-tooltip"]').text()).not.toContain('hidden from the status summary')
    expect(wrapper.text()).not.toContain('Suspected')
  })

  it('reloads on a visible refresh revision and skips hidden-page polling', async () => {
    const visibility = vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    const wrapper = mount(ChannelMonitorV3QualityHistory, { props: { groupId: 17, enabled: true } })
    await flushPromises()
    expect(getQualityEvents).toHaveBeenCalledTimes(1)

    visibility.mockReturnValue('hidden')
    await wrapper.setProps({ refreshRevision: 1 })
    await flushPromises()
    expect(getQualityEvents).toHaveBeenCalledTimes(1)

    visibility.mockReturnValue('visible')
    await wrapper.setProps({ refreshRevision: 2 })
    await flushPromises()
    expect(getQualityEvents).toHaveBeenCalledTimes(2)
  })
})
