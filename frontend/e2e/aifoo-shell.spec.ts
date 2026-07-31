import { expect, test, type Page } from '@playwright/test'
import { PNG } from 'pngjs'

const LEGACY_OVERRIDE_PATTERN = /\/(?:shell-bootstrap|console-override|auth-override|auth-preload|auth-theme-toggle)(?:\.|\/|\?|$)/

function assertImageHasVisibleVariation(image: Buffer) {
  const png = PNG.sync.read(image)
  const colors = new Set<string>()
  let opaquePixels = 0

  for (let index = 0; index < png.data.length; index += 4) {
    const alpha = png.data[index + 3]
    if (alpha < 32) continue
    opaquePixels += 1
    colors.add(`${png.data[index] >> 4}:${png.data[index + 1] >> 4}:${png.data[index + 2] >> 4}`)
  }

  expect(opaquePixels).toBeGreaterThan((png.width * png.height) / 2)
  expect(colors.size).toBeGreaterThan(24)
}

async function assertNoHorizontalOverflow(page: Page) {
  const dimensions = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth
  }))

  expect(dimensions.document).toBeLessThanOrEqual(dimensions.viewport + 1)
  expect(dimensions.body).toBeLessThanOrEqual(dimensions.viewport + 1)
}

test('login is source-rendered, visible, responsive, and free of legacy overrides', async ({ page }, testInfo) => {
  const legacyRequests: string[] = []
  page.on('request', request => {
    if (LEGACY_OVERRIDE_PATTERN.test(new URL(request.url()).pathname)) {
      legacyRequests.push(request.url())
    }
  })

  await page.goto('/login', { waitUntil: 'domcontentloaded' })

  await expect(page.locator('body')).toHaveClass(/auth-landing-page/)
  await expect(page.getByRole('img', { name: 'AIFoo' })).toBeVisible()
  await expect(page.getByRole('navigation', { name: '登录页快捷导航' })).toBeVisible()
  await expect(page.getByRole('link', { name: 'AI中转站' })).toBeVisible()
  await expect(page.getByRole('link', { name: '接入文档' })).toBeVisible()
  await expect(page.getByRole('link', { name: '模型价格' })).toBeVisible()
  await expect(page.locator('.aifoo-auth-card')).toBeVisible()

  const cardOpacity = await page.locator('.aifoo-auth-card').evaluate(element => getComputedStyle(element).opacity)
  expect(Number(cardOpacity)).toBeGreaterThan(0.95)

  await assertNoHorizontalOverflow(page)

  const screenshot = await page.screenshot({
    path: testInfo.outputPath('login.png'),
    fullPage: true
  })
  assertImageHasVisibleVariation(screenshot)
  expect(legacyRequests).toEqual([])
})

test('direct console route refresh returns to the source-built login shell', async ({ page }) => {
  const legacyRequests: string[] = []
  page.on('request', request => {
    if (LEGACY_OVERRIDE_PATTERN.test(new URL(request.url()).pathname)) {
      legacyRequests.push(request.url())
    }
  })

  await page.goto('/admin/dashboard', { waitUntil: 'domcontentloaded' })
  await expect(page).toHaveURL(/\/login(?:\?|$)/)
  await expect(page.locator('body')).toHaveClass(/auth-landing-page/)
  await expect(page.getByRole('img', { name: 'AIFoo' })).toBeVisible()
  await assertNoHorizontalOverflow(page)
  expect(legacyRequests).toEqual([])
})
