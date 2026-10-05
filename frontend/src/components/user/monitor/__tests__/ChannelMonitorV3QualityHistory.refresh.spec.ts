import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { getQualityEvents, getQualityEventArtwork } = vi.hoisted(() => ({
  getQualityEvents: vi.fn(),
  getQualityEventArtwork: vi.fn(),
}))

vi.mock('@/api/channelMonitorV2', () => ({
  getQualityEvents: (...args: unknown[]) => getQualityEvents(...args),
  getQualityEventArtwork,
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

  it('reloads group results when the monitor refresh revision changes', async () => {
    const wrapper = mount(ChannelMonitorV3QualityHistory, {
      props: { groupId: 17, enabled: true, refreshRevision: 1 },
    })
    await flushPromises()
    expect(getQualityEvents).toHaveBeenCalledTimes(1)
    expect(getQualityEvents).toHaveBeenLastCalledWith(17, 30)

    getQualityEvents.mockResolvedValue([{
      id: 82,
      group_id: 17,
      account_id: 3,
      model_id: 'gpt-5',
      status: 'degraded',
      quality_mode: 'candy',
      error_message: '',
      created_at: '2026-10-02T04:00:00Z',
    }])
    await wrapper.setProps({ refreshRevision: 2 })
    await flushPromises()

    expect(getQualityEvents).toHaveBeenCalledTimes(2)
    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryDegraded')
  })
  it('skips hidden-page polling and reloads on the next visible refresh', async () => {
    const visibility = vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    const wrapper = mount(ChannelMonitorV3QualityHistory, { props: { groupId: 17, enabled: true } })
    await flushPromises()
    visibility.mockReturnValue('hidden')
    await wrapper.setProps({ refreshRevision: 1 }); await flushPromises()
    expect(getQualityEvents).toHaveBeenCalledTimes(1)
    visibility.mockReturnValue('visible')
    await wrapper.setProps({ refreshRevision: 2 }); await flushPromises()
    expect(getQualityEvents).toHaveBeenCalledTimes(2)
  })

  it('keeps touch devices to status chips without opening result details', async () => {
    vi.spyOn(window, 'matchMedia').mockReturnValue({ matches: true } as MediaQueryList)
    getQualityEvents.mockResolvedValue([{
      id: 90,
      group_id: 17,
      account_id: 3,
      model_id: 'gpt-5',
      status: 'success',
      quality_mode: 'pelican',
      error_message: '',
      created_at: '2026-10-02T04:00:00Z',
    }, {
      id: 91,
      group_id: 17,
      account_id: 3,
      model_id: 'gpt-5',
      status: 'unknown',
      quality_mode: 'candy',
      error_message: '',
      created_at: '2026-10-02T04:01:00Z',
    }])
    const wrapper = mount(ChannelMonitorV3QualityHistory, { props: { groupId: 17, enabled: true } })
    await flushPromises()

    const chips = wrapper.findAll('[data-testid^="quality-history-chip-"]')
    expect(chips[1].classes()).toContain('is-unknown')
    await chips[0].trigger('mouseenter')
    await flushPromises()
    expect(wrapper.find('[data-testid="quality-history-popover"]').exists()).toBe(false)
    expect(getQualityEventArtwork).not.toHaveBeenCalled()
  })

})
