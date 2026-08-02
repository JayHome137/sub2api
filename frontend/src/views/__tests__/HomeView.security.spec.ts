import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'
import HomeView from '../HomeView.vue'

const stores = vi.hoisted(() => ({
  app: {
    cachedPublicSettings: {
      home_content: '',
    },
    siteName: 'Sub2API',
    siteLogo: '',
    docUrl: '',
    publicSettingsLoaded: true,
    fetchPublicSettings: vi.fn(),
  },
  auth: {
    isAuthenticated: false,
    isAdmin: false,
    user: null,
    checkAuth: vi.fn(),
  },
}))

vi.mock('@/stores', () => ({
  useAppStore: () => stores.app,
  useAuthStore: () => stores.auth,
}))

vi.mock('vue-i18n', async (importOriginal) => ({
  ...(await importOriginal<typeof import('vue-i18n')>()),
  useI18n: () => ({ t: (key: string) => key }),
}))

function mountHome() {
  return mount(HomeView, {
    global: {
      stubs: {
        Icon: true,
        LocaleSwitcher: true,
        RouterLink: true,
      },
    },
  })
}

describe('HomeView custom content security', () => {
  afterEach(() => {
    stores.app.cachedPublicSettings.home_content = ''
    vi.clearAllMocks()
  })

  it('renders a sanitized URL in a restricted iframe', () => {
    stores.app.cachedPublicSettings.home_content = ' https://example.com/welcome '
    const wrapper = mountHome()
    const iframe = wrapper.get('iframe')

    expect(iframe.attributes('src')).toBe('https://example.com/welcome')
    expect(iframe.attributes('sandbox')).toBe(
      'allow-forms allow-popups allow-popups-to-escape-sandbox allow-scripts',
    )
    expect(iframe.attributes('referrerpolicy')).toBe('no-referrer')
  })

  it('sanitizes custom HTML before rendering it', () => {
    stores.app.cachedPublicSettings.home_content =
      '<main><h1>Welcome</h1><img src="/logo.svg" onerror="alert(1)"><script>alert(2)</script></main>'
    const wrapper = mountHome()

    expect(wrapper.get('h1').text()).toBe('Welcome')
    expect(wrapper.get('img').attributes('src')).toBe('/logo.svg')
    expect(wrapper.get('img').attributes('onerror')).toBeUndefined()
    expect(wrapper.find('script').exists()).toBe(false)
    expect(wrapper.find('iframe').exists()).toBe(false)
  })
})
