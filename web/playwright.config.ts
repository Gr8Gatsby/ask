import { defineConfig, devices } from '@playwright/test'

// E2E config — runs against the vite proxy at localhost:5173. The proxy
// forwards /api to BACKEND_PORT (4242 = AskMac, 4243 = mock).
// If vite isn't already running, `webServer` below starts it; an existing
// vite is reused via `reuseExistingServer`. When BACKEND_PORT=4243, vite
// is started via `npm run dev:mock` so the mock server comes up alongside it.

const backendPort = process.env.BACKEND_PORT ?? '4242'
const useMock = backendPort === '4243'
const viteCmd = useMock ? 'npm run dev:mock' : 'npm run dev'

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,    // shared backend state — keep tests serial
  retries: 0,
  workers: 1,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],
  use: {
    baseURL: 'http://localhost:5173',
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  webServer: {
    command: viteCmd,
    url: 'http://localhost:5173',
    reuseExistingServer: true,
    timeout: 60_000,
    stdout: 'ignore',
    stderr: 'pipe',
  },
  projects: [
    {
      name: 'desktop',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1400, height: 900 },
      },
    },
  ],
})
