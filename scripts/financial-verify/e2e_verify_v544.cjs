/* 部署后端到端三验（v5.44）：PC 分流 / H5 走势卡品种切换 / H5 登录弹框自适应 */
const { chromium, devices } = require('D:/Workspace/financial/financial-web/node_modules/playwright')

const BASE = 'http://192.168.31.200'

function ok(name, pass, detail = '') {
  console.log(`${pass ? 'PASS' : 'FAIL'} | ${name}${detail ? ' | ' + detail : ''}`)
  if (!pass) process.exitCode = 2
}

async function openAuthModalByText(page, isPhone) {
  // PC：登录入口在"用户"下拉面板内，先展开面板
  if (!isPhone) {
    const userBtn = page.getByRole('button', { name: /用户/ }).first()
    if (await userBtn.count() > 0) {
      try { await userBtn.click({ timeout: 2500 }) } catch (e) { /* next */ }
    }
  }
  const candidates = ['登录', '登录 / 注册', 'Login', 'Sign in']
  for (const t of candidates) {
    const loc = page.getByText(t, { exact: true }).first()
    if (await loc.count() > 0) {
      try { await loc.click({ timeout: 2500 }); return t } catch (e) { /* next */ }
    }
  }
  return null
}

;(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true })

  // ---------- PC ----------
  {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } })
    const page = await ctx.newPage()
    await page.goto(BASE + '/', { waitUntil: 'domcontentloaded' })
    await page.waitForTimeout(3500)
    const summary = await page.locator('.fb-home-ea-account-summary').count()
    const trend = await page.locator('.trend-card').count()
    ok('PC 有账户金额卡', summary > 0, `count=${summary}`)
    ok('PC 无走势卡', trend === 0, `count=${trend}`)

    const clicked = await openAuthModalByText(page, false)
    await page.waitForTimeout(800)
    const overlay = page.locator('.auth-modal-overlay')
    const hasOverlay = await overlay.count() > 0
    ok('PC 登录弹框可打开', hasOverlay, clicked ? `via=${clicked}` : 'no trigger found')
    if (hasOverlay) {
      const isPhone = await page.locator('.auth-modal-overlay--phone').count() > 0
      ok('PC 弹框非手机形态', !isPhone, `isPhone=${isPhone}`)
    }
    await ctx.close()
  }

  // ---------- H5 ----------
  {
    const ctx = await browser.newContext({ ...devices['iPhone 13'] })
    const page = await ctx.newPage()
    await page.goto(BASE + '/', { waitUntil: 'domcontentloaded' })
    await page.waitForTimeout(4000)

    const trend = page.locator('.trend-card')
    const hasTrend = await trend.count() > 0
    ok('H5 有走势卡', hasTrend)
    const summary = await page.locator('.fb-home-ea-account-summary').count()
    ok('H5 无账户金额卡', summary === 0, `count=${summary}`)

    if (hasTrend) {
      const tabs = await page.locator('.trend-card__tab').allTextContents()
      ok('H5 品种 tab 齐全(4)', tabs.length === 4, tabs.join('/'))
      // 等首屏行情落定（接口+渲染）
      await page.waitForFunction(() => {
        const el = document.querySelector('.trend-card__price strong')
        return el && el.textContent && el.textContent.trim() !== '--'
      }, null, { timeout: 8000 }).catch(() => {})
      const sub0 = await page.locator('.trend-card__sub').textContent()
      ok('H5 默认黄金 XAUUSD', /XAUUSD/.test(sub0 || ''), `sub=${sub0}`)
      const price0 = (await page.locator('.trend-card__price strong').textContent() || '').trim()
      ok('H5 黄金价有真实数值', price0 !== '--' && /\d/.test(price0), `price=${price0}`)

      // 切到白银
      const silver = page.getByRole('tab', { name: '白银' })
      if (await silver.count() > 0) {
        await silver.click()
        await page.waitForFunction(() => {
          const s = document.querySelector('.trend-card__sub')
          const el = document.querySelector('.trend-card__price strong')
          return s && /XAGUSD/.test(s.textContent || '') && el && el.textContent && el.textContent.trim() !== '--'
        }, null, { timeout: 8000 }).catch(() => {})
        const sub1 = await page.locator('.trend-card__sub').textContent()
        ok('H5 切品种→白银 XAGUSD', /XAGUSD/.test(sub1 || ''), `sub=${sub1}`)
        const price1 = (await page.locator('.trend-card__price strong').textContent() || '').trim()
        ok('H5 白银价有真实数值', price1 !== '--' && /\d/.test(price1), `before=${price0} after=${price1}`)
      } else {
        ok('H5 白银 tab 可点', false)
      }
    }

    // 登录弹框自适应
    const clicked = await openAuthModalByText(page, true)
    await page.waitForTimeout(800)
    const overlay = page.locator('.auth-modal-overlay')
    const hasOverlay = await overlay.count() > 0
    ok('H5 登录弹框可打开', hasOverlay, clicked ? `via=${clicked}` : 'no trigger found')
    if (hasOverlay) {
      const isPhone = await page.locator('.auth-modal-overlay--phone').count() > 0
      ok('H5 弹框=手机形态', isPhone, `isPhone=${isPhone}`)
      if (isPhone) {
        const box = await page.locator('.auth-modal').boundingBox()
        const vh = page.viewportSize().height
        ok('H5 弹框全屏高', box && Math.abs(box.height - vh) <= 2, `h=${box && box.height} vh=${vh}`)
        const radius = await page.locator('.auth-modal').evaluate((el) => getComputedStyle(el).borderRadius)
        ok('H5 弹框无圆角', radius === '0px', `radius=${radius}`)
      }
    }
    await ctx.close()
  }

  await browser.close()
  function failedText(v) { return !v || v === '--' }
})().catch((e) => { console.error('E2E_ERROR', e); process.exit(3) })
