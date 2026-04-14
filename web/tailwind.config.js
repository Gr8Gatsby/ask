/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ask: {
          // All colors reference CSS variables so they swap per platform.
          // The `<alpha-value>` placeholder lets Tailwind opacity modifiers work
          // (e.g. bg-ask-card/20, border-ask-sep/50).
          bg:        'rgb(var(--pt-bg)        / <alpha-value>)',
          card:      'rgb(var(--pt-card)      / <alpha-value>)',
          card2:     'rgb(var(--pt-card2)     / <alpha-value>)',
          text:      'rgb(var(--pt-text)      / <alpha-value>)',
          secondary: 'rgb(var(--pt-secondary) / <alpha-value>)',
          sep:       'rgb(var(--pt-sep)       / <alpha-value>)',
          blue:      'rgb(var(--pt-blue)      / <alpha-value>)',
          green:     'rgb(var(--pt-green)     / <alpha-value>)',
          orange:    'rgb(var(--pt-orange)    / <alpha-value>)',
          red:       'rgb(var(--pt-red)       / <alpha-value>)',
          yellow:    'rgb(var(--pt-yellow)    / <alpha-value>)',
          purple:    'rgb(var(--pt-purple)    / <alpha-value>)',
        },
      },
      fontFamily: {
        // CSS variable lets platform class swap fonts (Roboto on Android)
        sans: ['var(--font-sans)'],
        mono: ['var(--font-mono)'],
      },
    },
  },
  plugins: [],
}
