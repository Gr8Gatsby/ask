/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ask: {
          bg: '#1c1c1e',
          card: '#2c2c2e',
          card2: '#3a3a3c',
          text: '#ffffff',
          secondary: '#8e8e93',
          sep: '#38383a',
          orange: '#ff9f0a',
          red: '#ff453a',
          green: '#32d74b',
          blue: '#0a84ff',
          yellow: '#ffd60a',
          purple: '#bf5af2',
        },
      },
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', 'SF Pro Text', 'Helvetica Neue', 'sans-serif'],
        mono: ['SF Mono', 'ui-monospace', 'Menlo', 'monospace'],
      },
    },
  },
  plugins: [],
}
