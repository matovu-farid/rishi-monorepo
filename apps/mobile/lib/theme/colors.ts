// Semantic color tokens matching iOS UIKit semantics.
// All rgba values are intentional — they composite correctly on tinted surfaces.

export type ColorTokens = {
  background: {
    primary: string
    secondary: string
    tertiary: string
    grouped: string
  }
  label: {
    primary: string
    secondary: string
    tertiary: string
    quaternary: string
  }
  fill: {
    primary: string
    secondary: string
    tertiary: string
    quaternary: string
  }
  separator: {
    opaque: string
    nonOpaque: string
  }
  accent: {
    primary: string
    success: string
    warning: string
    error: string
  }
  reader: {
    paper: string
    ink: string
    paperPureWhite: string
    paperSepia: string
  }
  highlight: {
    yellow: string
    green: string
    blue: string
    pink: string
    purple: string
  }
}

export const colorsLight: ColorTokens = {
  background: {
    primary: '#FFFFFF',
    secondary: '#F2F2F7',
    tertiary: '#FFFFFF',
    grouped: '#F2F2F7',
  },
  label: {
    primary: '#000000',
    secondary: 'rgba(60,60,67,0.60)',
    tertiary: 'rgba(60,60,67,0.30)',
    quaternary: 'rgba(60,60,67,0.18)',
  },
  fill: {
    primary: 'rgba(120,120,128,0.20)',
    secondary: 'rgba(120,120,128,0.16)',
    tertiary: 'rgba(118,118,128,0.12)',
    quaternary: 'rgba(116,116,128,0.08)',
  },
  separator: {
    opaque: '#C6C6C8',
    nonOpaque: 'rgba(60,60,67,0.29)',
  },
  accent: {
    primary: '#0a7ea4',
    success: '#34C759',
    warning: '#FF9F0A',
    error: '#FF3B30',
  },
  reader: {
    paper: '#FAF8F3',
    ink: '#1C1C1E',
    paperPureWhite: '#FFFFFF',
    paperSepia: '#F6F0E2',
  },
  highlight: {
    yellow: 'rgba(255,224,102,0.45)',
    green: 'rgba(143,225,158,0.45)',
    blue: 'rgba(143,196,255,0.45)',
    pink: 'rgba(255,170,200,0.45)',
    purple: 'rgba(204,178,242,0.45)',
  },
}

export const colorsDark: ColorTokens = {
  background: {
    primary: '#000000',
    secondary: '#1C1C1E',
    tertiary: '#2C2C2E',
    grouped: '#000000',
  },
  label: {
    primary: '#FFFFFF',
    secondary: 'rgba(235,235,245,0.60)',
    tertiary: 'rgba(235,235,245,0.30)',
    quaternary: 'rgba(235,235,245,0.18)',
  },
  fill: {
    primary: 'rgba(120,120,128,0.36)',
    secondary: 'rgba(120,120,128,0.32)',
    tertiary: 'rgba(118,118,128,0.24)',
    quaternary: 'rgba(118,118,128,0.18)',
  },
  separator: {
    opaque: '#38383A',
    nonOpaque: 'rgba(84,84,88,0.65)',
  },
  accent: {
    primary: '#3AB4D6',
    success: '#30D158',
    warning: '#FF9F0A',
    error: '#FF453A',
  },
  reader: {
    paper: '#000000',
    ink: '#B8B8B9',
    paperPureWhite: '#FFFFFF',
    paperSepia: '#F6F0E2',
  },
  highlight: {
    yellow: 'rgba(255,224,102,0.32)',
    green: 'rgba(143,225,158,0.32)',
    blue: 'rgba(143,196,255,0.32)',
    pink: 'rgba(255,170,200,0.32)',
    purple: 'rgba(204,178,242,0.32)',
  },
}
