import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

vi.mock('@/stores/app', () => ({ useAppStore: () => ({ showSuccess: vi.fn(), showError: vi.fn() }) }))
vi.mock('@/utils/featureFlags', () => ({ getChannelMonitorMode: () => 'v2', isChannelMonitorV2Mode: () => true }))
vi.mock('vue-i18n', async importOriginal => ({
  ...await importOriginal<typeof import('vue-i18n')>(),
  useI18n: () => ({ t: (key: string) => key, te: () => false }),
}))
vi.mock('@/api/admin', () => ({ adminAPI: { groups: { getAllIncludingInactive: vi.fn() } } }))
vi.mock('@/api/channelMonitorV2', async importOriginal => ({
  ...await importOriginal<typeof import('@/api/channelMonitorV2')>(),
  getConfig: vi.fn(), updateConfig: vi.fn(),
}))

import MonitorSettingsPanel from '../MonitorSettingsPanel.vue'
import { getConfig, updateConfig, type MonitorConfig } from '@/api/channelMonitorV2'
import { adminAPI } from '@/api/admin'

enableAutoUnmount(afterEach)
const config = { version: 1, enabled: true, group_ids: [], platforms: [], refresh_interval_seconds: 60 } as unknown as MonitorConfig
const button = (wrapper: ReturnType<typeof mount>, key: string) => wrapper.findAll('button').find(b => b.text() === `channelMonitorV2.settings.${key}`)!
const groupBoxes = (wrapper: ReturnType<typeof mount>) => wrapper.findAll('label').filter(l => /#\d+/.test(l.text())).map(l => l.get('input'))

beforeEach(() => {
  vi.mocked(getConfig).mockResolvedValue(structuredClone(config))
  vi.mocked(adminAPI.groups.getAllIncludingInactive).mockResolvedValue([{ id: 12, name: 'A', platform: 'openai' }, { id: 19, name: 'B', platform: 'anthropic' }] as never)
  vi.mocked(updateConfig).mockClear().mockImplementation(async value => JSON.parse(JSON.stringify({ ...value, version: value.version + 1 })))
})

it('shows legacy all-groups config as checked, then saves none as disabled', async () => {
  const wrapper = mount(MonitorSettingsPanel, { global: { stubs: { Icon: true, RouterLink: true } } })
  await flushPromises()
  expect(groupBoxes(wrapper).map(box => (box.element as HTMLInputElement).checked)).toEqual([true, true])
  await button(wrapper, 'clearGroups').trigger('click')
  await button(wrapper, 'save').trigger('click')
  await flushPromises()
  expect(updateConfig).toHaveBeenLastCalledWith(expect.objectContaining({ enabled: false, group_ids: [] }))
  expect(groupBoxes(wrapper).every(box => !(box.element as HTMLInputElement).checked)).toBe(true)
})

it('reenables monitoring for exactly the newly selected group after an empty selection', async () => {
  vi.mocked(getConfig).mockResolvedValue({ ...config, enabled: false })
  const wrapper = mount(MonitorSettingsPanel, { global: { stubs: { Icon: true, RouterLink: true } } })
  await flushPromises()
  await groupBoxes(wrapper)[0].setValue(true)
  await button(wrapper, 'save').trigger('click')
  await flushPromises()
  expect(updateConfig).toHaveBeenLastCalledWith(expect.objectContaining({ enabled: true, group_ids: [12] }))
  await groupBoxes(wrapper)[0].setValue(false)
  await button(wrapper, 'save').trigger('click')
  await flushPromises()
  expect(updateConfig).toHaveBeenLastCalledWith(expect.objectContaining({ enabled: false, group_ids: [] }))
})

it('saves an explicit list on select-all rather than the backend empty-list wildcard', async () => {
  vi.mocked(getConfig).mockResolvedValue({ ...config, enabled: false })
  const wrapper = mount(MonitorSettingsPanel, { global: { stubs: { Icon: true, RouterLink: true } } })
  await flushPromises()
  await button(wrapper, 'selectAllGroups').trigger('click')
  await button(wrapper, 'save').trigger('click')
  await flushPromises()
  expect(updateConfig).toHaveBeenLastCalledWith(expect.objectContaining({ enabled: true, group_ids: [12, 19] }))
})
