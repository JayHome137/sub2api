import { reactive } from 'vue'
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'
import AppLayout from '../AppLayout.vue'

const route = reactive({ path: '/dashboard' })
vi.mock('vue-router', () => ({ useRoute: () => route }))
vi.mock('@/stores', () => ({ useAppStore: () => ({ sidebarCollapsed: false }) }))
vi.mock('@/stores/auth', () => ({ useAuthStore: () => ({ user: { role: 'user' } }) }))
vi.mock('@/stores/onboarding', () => ({ useOnboardingStore: () => ({ setReplayCallback: vi.fn() }) }))
vi.mock('@/composables/useOnboardingTour', () => ({ useOnboardingTour: () => ({ replayTour: vi.fn() }) }))
vi.mock('../AppSidebar.vue', () => ({ default: { template: '<aside />' } }))
vi.mock('../AppHeader.vue', () => ({ default: { template: '<header />' } }))

afterEach(() => {
  document.documentElement.className = ''
  document.body.className = ''
})

describe('AIFoo route theme ownership', () => {
  it('cleans the applied route even when the router has advanced before unmount', () => {
    route.path = '/dashboard'
    const previous = mount(AppLayout)
    route.path = '/admin/dashboard'
    previous.unmount()
    const current = mount(AppLayout)
    expect([...document.documentElement.classList].filter(name => name.startsWith('route-')))
      .toEqual(['route-admin-dashboard'])
    current.unmount()
    expect(document.documentElement.classList.contains('console-shell')).toBe(false)
  })

  it('replaces bootstrap route markers after a redirect without removing the theme', () => {
    document.documentElement.className = 'dark console-shell route-dashboard route-admin-usage'
    route.path = '/admin/accounts'
    const wrapper = mount(AppLayout)
    expect(document.documentElement.className).toBe('dark console-shell route-admin-accounts')
    wrapper.unmount()
    expect(document.documentElement.className).toBe('dark')
  })

  it('does not remove a newer layout theme during old layout cleanup', () => {
    route.path = '/dashboard'
    const previous = mount(AppLayout)
    route.path = '/usage'
    const current = mount(AppLayout)
    previous.unmount()
    expect(document.documentElement.className).toBe('console-shell route-usage')
    current.unmount()
  })
})
