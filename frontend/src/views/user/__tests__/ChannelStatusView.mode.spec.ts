import { describe, expect, it, vi, beforeEach } from 'vitest'
import { defineComponent, h } from 'vue'
import { mount } from '@vue/test-utils'

const isV1 = vi.fn(() => false)

vi.mock('@/utils/featureFlags', () => ({
  isChannelMonitorV1Mode: () => isV1(),
}))

vi.mock('../ChannelStatusV1View.vue', () => ({
  default: defineComponent({ name: 'ChannelStatusV1View', setup: () => () => h('div', { 'data-testid': 'v1' }) }),
}))
vi.mock('../ChannelStatusV2View.vue', () => ({
  default: defineComponent({ name: 'ChannelStatusV2View', setup: () => () => h('div', { 'data-testid': 'v2' }) }),
}))
vi.mock('../ChannelStatusV3View.vue', () => ({
  default: defineComponent({ name: 'ChannelStatusV3View', setup: () => () => h('div', { 'data-testid': 'v3' }) }),
}))

import ChannelStatusView from '../ChannelStatusView.vue'

describe('ChannelStatusView mode switch', () => {
  beforeEach(() => {
    isV1.mockReset()
    window.history.replaceState({}, '', '/monitor')
  })

  it('renders V3 using the official V2 mode', () => {
    isV1.mockReturnValue(false)
    const wrapper = mount(ChannelStatusView)
    expect(wrapper.find('[data-testid="v3"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="v1"]').exists()).toBe(false)
  })

  it('retains V2 as an explicit diagnostic fallback', () => {
    window.history.replaceState({}, '', '/monitor?monitor_view=v2')
    isV1.mockReturnValue(false)
    const wrapper = mount(ChannelStatusView)
    expect(wrapper.find('[data-testid="v2"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="v3"]').exists()).toBe(false)
  })

  it('renders V1 when in v1 mode', () => {
    isV1.mockReturnValue(true)
    const wrapper = mount(ChannelStatusView)
    expect(wrapper.find('[data-testid="v1"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="v2"]').exists()).toBe(false)
  })
})
