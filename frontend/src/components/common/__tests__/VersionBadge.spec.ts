import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import VersionBadge from '../VersionBadge.vue'

const { appStore, authStore, systemMutations } = vi.hoisted(() => ({
  appStore: {
    versionLoading: false,
    currentVersion: '0.1.169',
    latestVersion: '0.1.169',
    hasUpdate: false,
    releaseInfo: null as { html_url?: string } | null,
    fetchVersion: vi.fn(),
  },
  authStore: {
    isAdmin: false,
  },
  systemMutations: {
    performUpdate: vi.fn(),
    restartService: vi.fn(),
    getRollbackVersions: vi.fn(),
    rollback: vi.fn(),
  },
}))

vi.mock('@/stores', () => ({
  useAppStore: () => appStore,
  useAuthStore: () => authStore,
}))

vi.mock('@/api/admin/system', () => systemMutations)

vi.mock('vue-i18n', async (importOriginal) => ({
  ...(await importOriginal<typeof import('vue-i18n')>()),
  useI18n: () => ({ t: (key: string) => key }),
}))

function mountBadge() {
  return mount(VersionBadge, {
    props: { version: '0.1.169' },
    global: {
      stubs: {
        Icon: { template: '<span data-testid="icon" />' },
      },
    },
  })
}

describe('VersionBadge AIFoo upgrade status', () => {
  beforeEach(() => {
    authStore.isAdmin = false
    appStore.versionLoading = false
    appStore.currentVersion = '0.1.169'
    appStore.latestVersion = '0.1.169'
    appStore.hasUpdate = false
    appStore.releaseInfo = null
    appStore.fetchVersion.mockReset()
    appStore.fetchVersion.mockResolvedValue({
      current_version: '0.1.169',
      latest_version: '0.1.169',
      has_update: false,
    })
    Object.values(systemMutations).forEach((mock) => mock.mockReset())
  })

  it('keeps the private upgrade entry hidden from non-admin users', async () => {
    const wrapper = mountBadge()
    await flushPromises()

    expect(wrapper.text()).toContain('v0.1.169')
    expect(wrapper.find('[data-testid="version-badge"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="github-upgrade-status-link"]').exists()).toBe(false)
    expect(appStore.fetchVersion).not.toHaveBeenCalled()
  })

  it('opens the private GitHub status page with a safe external link', async () => {
    authStore.isAdmin = true
    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    const link = wrapper.get('[data-testid="github-upgrade-status-link"]')
    expect(link.attributes('href')).toContain('github.com/JayHome137/sub2api/issues')
    expect(link.attributes('href')).toContain('label%3Aupstream-release')
    expect(link.attributes('target')).toBe('_blank')
    expect(link.attributes('rel')).toBe('noopener noreferrer')
    expect(appStore.fetchVersion).toHaveBeenCalledWith(false)
  })

  it('shows a detected stable release without offering local update actions', async () => {
    authStore.isAdmin = true
    appStore.hasUpdate = true
    appStore.latestVersion = '0.1.170'
    appStore.releaseInfo = {
      html_url: 'https://github.com/Wei-Shaw/sub2api/releases/tag/v0.1.170',
    }

    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    expect(wrapper.get('[data-testid="upgrade-status-detected"]').text()).toContain('v0.1.170')
    expect(wrapper.text()).not.toContain('version.updateNow')
    expect(wrapper.text()).not.toContain('version.rollback')
    expect(wrapper.text()).not.toContain('version.restartNow')
  })

  it('does not report up-to-date when the release check is unavailable', async () => {
    authStore.isAdmin = true
    appStore.fetchVersion.mockResolvedValue(null)

    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    expect(wrapper.find('[data-testid="upgrade-status-unavailable"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="upgrade-status-watching"]').exists()).toBe(false)
  })

  it('refreshes only the read-only release check and never calls system mutations', async () => {
    authStore.isAdmin = true
    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')
    await wrapper.get('[title="version.refresh"]').trigger('click')
    await flushPromises()

    expect(appStore.fetchVersion).toHaveBeenLastCalledWith(true)
    expect(systemMutations.performUpdate).not.toHaveBeenCalled()
    expect(systemMutations.restartService).not.toHaveBeenCalled()
    expect(systemMutations.getRollbackVersions).not.toHaveBeenCalled()
    expect(systemMutations.rollback).not.toHaveBeenCalled()
  })
})
