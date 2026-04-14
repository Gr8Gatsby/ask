import { useMemo } from 'react'
import { createTheme } from '@mui/material/styles'
import { usePlatform } from './PlatformContext'

// M3 color tokens — matched to index.css --pt-* values for each platform/theme
const DARK = {
  mode: 'dark' as const,
  primary:    { main: '#d0bcff', contrastText: '#381e72' },
  secondary:  { main: '#ccc2dc', contrastText: '#332d41' },
  background: { default: '#141218', paper: '#211f26' },
  text:       { primary: '#e6e1e5', secondary: '#cac4d0' },
  error:      { main: '#f2b8b5', contrastText: '#601410' },
  success:    { main: '#a8c7a0', contrastText: '#1e3722' },
  warning:    { main: '#ffb74d', contrastText: '#4a2800' },
  divider:    'rgba(73,69,79,0.6)',
  action: {
    hover:           'rgba(208,188,255,0.08)',
    selected:        'rgba(208,188,255,0.12)',
    disabledBackground: 'rgba(230,225,229,0.12)',
  },
}

const LIGHT = {
  mode: 'light' as const,
  primary:    { main: '#6750a4', contrastText: '#ffffff' },
  secondary:  { main: '#625b71', contrastText: '#ffffff' },
  background: { default: '#fffbfe', paper: '#ede8ef' },
  text:       { primary: '#1c1b1f', secondary: '#49454f' },
  error:      { main: '#b3261e', contrastText: '#ffffff' },
  success:    { main: '#377547', contrastText: '#ffffff' },
  warning:    { main: '#9a5a00', contrastText: '#ffffff' },
  divider:    'rgba(121,116,126,0.4)',
  action: {
    hover:           'rgba(103,80,164,0.08)',
    selected:        'rgba(103,80,164,0.12)',
    disabledBackground: 'rgba(28,27,31,0.12)',
  },
}

export function useMuiTheme() {
  const { themeMode } = usePlatform()
  return useMemo(() => createTheme({
    palette: themeMode === 'light' ? LIGHT : DARK,

    // M3 type scale — exact values from m3.material.io/styles/typography/type-scale-tokens
    typography: {
      fontFamily: '"Roboto", system-ui, sans-serif',
      // Map to MUI variants closest to M3 roles
      h5:       { fontSize: '24px', fontWeight: 400, lineHeight: '32px' },   // Headline Small
      h6:       { fontSize: '22px', fontWeight: 400, lineHeight: '28px' },   // Title Large
      subtitle1: { fontSize: '16px', fontWeight: 500, lineHeight: '24px', letterSpacing: 0 }, // Title Medium
      subtitle2: { fontSize: '14px', fontWeight: 500, lineHeight: '20px', letterSpacing: 0 }, // Title Small
      body1:    { fontSize: '16px', fontWeight: 400, lineHeight: '24px', letterSpacing: 0 }, // Body Large
      body2:    { fontSize: '14px', fontWeight: 400, lineHeight: '20px', letterSpacing: 0 }, // Body Medium
      caption:  { fontSize: '12px', fontWeight: 400, lineHeight: '16px', letterSpacing: '0.4px' }, // Body Small
      overline: { fontSize: '11px', fontWeight: 500, lineHeight: '16px', letterSpacing: '0.5px', textTransform: 'none' as const }, // Label Small
      button:   { fontSize: '14px', fontWeight: 500, lineHeight: '20px', letterSpacing: '0.1px', textTransform: 'none' as const }, // Label Large
    },

    shape: { borderRadius: 4 }, // M3 Extra Small — base token; components override per spec

    components: {
      // ── Buttons — Full/pill shape, 40dp height, Label Large type ──────────
      MuiButton: {
        defaultProps: { disableElevation: true },
        styleOverrides: {
          root: {
            borderRadius: 100,       // M3: Full shape (pill)
            minHeight: '40px',
            paddingLeft: '24px',
            paddingRight: '24px',
            fontWeight: 500,
            fontSize: '14px',
            letterSpacing: '0.1px',
            textTransform: 'none',
          },
          sizeSmall: {
            minHeight: '32px',
            paddingLeft: '16px',
            paddingRight: '16px',
            fontSize: '13px',
          },
          startIcon: { '& > *:first-of-type': { fontSize: '18px' } },
          endIcon:   { '& > *:first-of-type': { fontSize: '18px' } },
        },
      },

      // ── Cards — Medium shape (12dp) ────────────────────────────────────────
      MuiCard: {
        styleOverrides: {
          root: {
            borderRadius: '12px',
            backgroundImage: 'none',
          },
        },
      },
      MuiCardContent: {
        styleOverrides: {
          root: { padding: '16px', '&:last-child': { paddingBottom: '16px' } },
        },
      },

      // ── Chips — Small shape (8dp), Label Large type ────────────────────────
      MuiChip: {
        styleOverrides: {
          root: {
            borderRadius: '8px',
            height: '32px',
            fontSize: '14px',
            fontWeight: 500,
            letterSpacing: '0.1px',
          },
          label: { paddingLeft: '12px', paddingRight: '12px' },
        },
      },

      // ── Text fields — Filled is M3's primary variant ───────────────────────
      // Filled: top corners 4dp (Extra Small), bottom square
      // Outlined: all corners 4dp (Extra Small)
      MuiTextField: {
        defaultProps: { variant: 'filled', size: 'small' },
      },
      MuiFilledInput: {
        defaultProps: { disableUnderline: false },
        styleOverrides: {
          root: {
            borderRadius: '4px 4px 0 0',
            '&:before': { borderBottomColor: 'rgba(var(--pt-sep),0.6)' },
            '&:hover:not(.Mui-disabled):before': { borderBottomColor: 'rgba(var(--pt-text),0.87)' },
          },
          input: { paddingTop: '20px', paddingBottom: '6px' },
        },
      },
      MuiOutlinedInput: {
        styleOverrides: {
          root: { borderRadius: '4px' },
        },
      },

      // ── Lists — M3 list item: 56dp height, 16dp horizontal padding ─────────
      MuiListItem: {
        styleOverrides: {
          root: { paddingLeft: '16px', paddingRight: '16px' },
        },
      },
      MuiListItemButton: {
        styleOverrides: {
          root: {
            minHeight: '56px',
            paddingLeft: '16px',
            paddingRight: '16px',
            borderRadius: 0,
          },
        },
      },
      MuiListItemText: {
        styleOverrides: {
          primary:   { fontSize: '16px', fontWeight: 400, lineHeight: '24px' },  // Body Large
          secondary: { fontSize: '14px', fontWeight: 400, lineHeight: '20px' },  // Body Medium
        },
      },

      // ── Dialogs — Extra Large shape (28dp) ─────────────────────────────────
      MuiDialog: {
        styleOverrides: {
          paper: { borderRadius: '28px', backgroundImage: 'none' },
        },
      },
      MuiDialogTitle: {
        styleOverrides: {
          root: { fontSize: '24px', fontWeight: 400, lineHeight: '32px', padding: '24px 24px 16px' }, // Headline Small
        },
      },
      MuiDialogContent: {
        styleOverrides: { root: { padding: '0 24px 24px' } },
      },
      MuiDialogActions: {
        styleOverrides: { root: { padding: '0 24px 24px', gap: '8px' } },
      },

      // ── Icon buttons ───────────────────────────────────────────────────────
      MuiIconButton: {
        styleOverrides: {
          root: { borderRadius: '50%' },
          sizeMedium: { width: '40px', height: '40px' },
          sizeSmall:  { width: '32px', height: '32px' },
        },
      },

      // ── Divider ────────────────────────────────────────────────────────────
      MuiDivider: {
        styleOverrides: { root: { borderColor: 'inherit', opacity: 0.4 } },
      },

      // ── Paper — no gradient, use flat surface colors ────────────────────────
      MuiPaper: {
        styleOverrides: { root: { backgroundImage: 'none' } },
      },

      // ── Select ─────────────────────────────────────────────────────────────
      MuiSelect: {
        defaultProps: { variant: 'filled' },
      },

      // ── Snackbar ───────────────────────────────────────────────────────────
      MuiSnackbar: {
        styleOverrides: { root: { borderRadius: '4px' } },
      },
    },
  }), [themeMode])
}

// M3 Banner — used instead of MUI Alert (which has no M3 equivalent).
// Surface Variant tinted container, left icon, title + optional body.
export const M3_BANNER_COLORS = {
  error:   { bg: 'rgba(242,184,181,0.15)', icon: '#f2b8b5',   border: 'rgba(242,184,181,0.3)'  },
  warning: { bg: 'rgba(255,183,77,0.12)',  icon: '#ffb74d',   border: 'rgba(255,183,77,0.3)'   },
  info:    { bg: 'rgba(208,188,255,0.12)', icon: '#d0bcff',   border: 'rgba(208,188,255,0.25)' },
  success: { bg: 'rgba(168,199,160,0.12)', icon: '#a8c7a0',  border: 'rgba(168,199,160,0.3)'  },
} as const

export const M3_BANNER_COLORS_LIGHT = {
  error:   { bg: 'rgba(179,38,30,0.08)',   icon: '#b3261e',  border: 'rgba(179,38,30,0.2)'    },
  warning: { bg: 'rgba(154,90,0,0.08)',    icon: '#9a5a00',  border: 'rgba(154,90,0,0.2)'     },
  info:    { bg: 'rgba(103,80,164,0.08)',  icon: '#6750a4',  border: 'rgba(103,80,164,0.2)'   },
  success: { bg: 'rgba(55,107,71,0.08)',   icon: '#377547',  border: 'rgba(55,107,71,0.2)'    },
} as const
