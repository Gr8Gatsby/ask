import { defineConfig, devices } from '@playwright/test'

// E2E config — runs against the live AskMac on port 4242 via the vite proxy
// at localhost:5173. The vite dev server is assumed to already be running
// (the user's normal dev workflow). If you're running these in CI without a
// live AskMac, point BACKEND_PORT at the mock server (see web/mock/server.ts)
// and start vite with that env var.

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
