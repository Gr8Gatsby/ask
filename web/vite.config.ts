import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// BACKEND_PORT=4242 → AskMac's LocalHTTPServer (default)
// BACKEND_PORT=4243 → local mock server (npm run dev:mock)
const backendPort = process.env.BACKEND_PORT ?? '4242'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: `http://localhost:${backendPort}`,
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
})
