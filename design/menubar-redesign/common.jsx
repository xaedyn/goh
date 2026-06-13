/* common.jsx — shared tokens, icons, scene chrome, sample data for goh menu bar directions */
/* eslint-disable */
const { useState, useEffect, useRef } = React;

// ── Brand tokens (locked identity-spec.md §2) ─────────────────────────────
const T = {
  ground:  '#0C0E14',   // dark ground
  type:    '#F4EDE0',   // warm paper type
  green:   '#6BFA9B',   // phosphor — ONLY ever means live / in-progress
  oxblood: '#9C5A4A',   // failed
  // derived
  dim:   'rgba(244,237,224,0.56)',
  faint: 'rgba(244,237,224,0.34)',
  ghost: 'rgba(244,237,224,0.16)',
  hair:  'rgba(244,237,224,0.10)',
  hair2: 'rgba(244,237,224,0.07)',
  greenDim: 'rgba(107,250,155,0.16)',
  fill:  'rgba(255,255,255,0.06)',
  fillH: 'rgba(255,255,255,0.10)',
};

const FONT = {
  ui:   '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif',
  mono: '"JetBrains Mono", ui-monospace, "SF Mono", monospace',
  serif:'"Fraunces", Georgia, "Times New Roman", serif',
};

// Inject keyframes + global helpers once.
if (!document.getElementById('goh-keyframes')) {
  const s = document.createElement('style');
  s.id = 'goh-keyframes';
  s.textContent = `
    @keyframes gohPulse { 0%,100%{opacity:1} 50%{opacity:.35} }
    @keyframes gohShimmer { 0%{transform:translateX(-100%)} 100%{transform:translateX(220%)} }
    @keyframes gohFlow { from{background-position:0 0} to{background-position:22px 0} }
    @keyframes gohRowIn { from{opacity:0; transform:translateY(5px)} to{opacity:1; transform:none} }
    .goh-row-hit { transition: background .12s ease; }
    .goh-btn { transition: background .12s ease, color .12s ease, border-color .12s ease, transform .06s ease; }
    .goh-btn:active { transform: translateY(0.5px); }
    @media (prefers-reduced-motion: reduce){ *{animation:none !important} }
  `;
  document.head.appendChild(s);
}

// ── Theme: dark (default) mirrors the original hardcoded values exactly; light
// is the inverse application — warm paper ground, dark ink, a deepened phosphor
// so "green = live" survives on a light surface (raw #6BFA9B is invisible there).
const PALETTE = {
  dark: {
    mode: 'dark', glow: true,
    type: T.type, dim: T.dim, faint: T.faint, ghost: T.ghost, hair: T.hair, hair2: T.hair2,
    fill: T.fill, fillH: T.fillH, green: T.green, greenDim: T.greenDim, oxblood: T.oxblood, onAccent: T.ground,
    popBg: 'linear-gradient(180deg, rgba(48,52,64,0.5), rgba(26,29,38,0.58))',
    notch: 'rgba(44,48,60,0.5)', topHi: 'rgba(255,255,255,0.14)',
    shadow: '0 22px 70px rgba(0,0,0,0.62), 0 6px 18px rgba(0,0,0,0.4)',
    track: 'rgba(255,255,255,0.08)',
    winBg: 'linear-gradient(180deg, rgba(26,29,38,0.96), rgba(15,17,23,0.97))',
    winShadow: 'inset 0 1px 0 rgba(255,255,255,0.07), 0 30px 90px rgba(0,0,0,0.6)',
    titleBar: 'rgba(255,255,255,0.02)', inset: 'rgba(0,0,0,0.25)', panel: 'rgba(255,255,255,0.025)',
    footer: 'rgba(0,0,0,0.18)', rowHover: 'rgba(255,255,255,0.035)', selRow: 'rgba(107,250,155,0.06)',
    ctaTint: 'rgba(107,250,155,0.05)', ctaTintH: 'rgba(107,250,155,0.1)', ctaBorder: 'rgba(107,250,155,0.16)',
    recovery: 'rgba(156,90,74,0.08)', recoveryBorder: 'rgba(156,90,74,0.3)', recoveryBtn: 'rgba(156,90,74,0.16)',
    fillBtn: 'rgba(255,255,255,0.05)', toggleOff: 'rgba(255,255,255,0.14)', knob: '#fff',
    wordmarkArrow: '#6BFA9B', dimArrow: 'rgba(244,237,224,0.5)', sha: 'rgba(244,237,224,0.42)',
  },
  light: {
    mode: 'light', glow: false,
    type: '#15140E', dim: 'rgba(21,20,14,0.62)', faint: 'rgba(21,20,14,0.42)', ghost: 'rgba(21,20,14,0.18)',
    hair: 'rgba(21,20,14,0.14)', hair2: 'rgba(21,20,14,0.08)', fill: 'rgba(21,20,14,0.05)', fillH: 'rgba(21,20,14,0.09)',
    green: '#0B7A43', greenDim: 'rgba(11,122,67,0.14)', oxblood: '#8A3A2A', onAccent: '#F8FBF6',
    popBg: 'linear-gradient(180deg, rgba(254,251,246,0.7), rgba(246,240,230,0.74))',
    notch: 'rgba(251,248,241,0.7)', topHi: 'rgba(255,255,255,0.75)',
    shadow: '0 22px 60px rgba(70,55,30,0.2), 0 6px 18px rgba(70,55,30,0.12)',
    track: 'rgba(21,20,14,0.12)',
    winBg: 'linear-gradient(180deg, rgba(253,250,245,0.98), rgba(245,239,229,0.98))',
    winShadow: 'inset 0 1px 0 rgba(255,255,255,0.6), 0 30px 90px rgba(60,48,24,0.22)',
    titleBar: 'rgba(21,20,14,0.025)', inset: 'rgba(21,20,14,0.05)', panel: 'rgba(21,20,14,0.035)',
    footer: 'rgba(21,20,14,0.04)', rowHover: 'rgba(21,20,14,0.05)', selRow: 'rgba(11,122,67,0.1)',
    ctaTint: 'rgba(11,122,67,0.08)', ctaTintH: 'rgba(11,122,67,0.14)', ctaBorder: 'rgba(11,122,67,0.28)',
    recovery: 'rgba(138,58,42,0.08)', recoveryBorder: 'rgba(138,58,42,0.3)', recoveryBtn: 'rgba(138,58,42,0.14)',
    fillBtn: 'rgba(21,20,14,0.05)', toggleOff: 'rgba(21,20,14,0.18)', knob: '#fff',
    wordmarkArrow: '#0B7A43', dimArrow: 'rgba(21,20,14,0.5)', sha: 'rgba(21,20,14,0.5)',
  },
};
const ThemeCtx = React.createContext(null);
function useTheme() { return React.useContext(ThemeCtx) || PALETTE.dark; }
function ThemeProvider({ mode = 'dark', children }) {
  return <ThemeCtx.Provider value={PALETTE[mode] || PALETTE.dark}>{children}</ThemeCtx.Provider>;
}

// ── Icon set (16px grid, stroke or fill) ──────────────────────────────────
const P = {
  refresh: 'M21 12a9 9 0 1 1-2.64-6.36 M21 4v5h-5',
  plus: 'M12 5v14 M5 12h14',
  gear: 'M5.5 12a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0 -13 0 M9.4 12a2.6 2.6 0 1 0 5.2 0a2.6 2.6 0 1 0 -5.2 0 M18.5 12L21 12 M12 18.5L12 21 M5.5 12L3 12 M12 5.5L12 3 M16.6 7.4L18.4 5.6 M7.4 7.4L5.6 5.6 M7.4 16.6L5.6 18.4 M16.6 16.6L18.4 18.4',
  terminal: 'M5 5h14a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z M7.5 9.5l2.5 2.5-2.5 2.5 M12.5 14.5h4',
  quit: 'M9.5 5H6a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h3.5 M15 8l4 4-4 4 M19 12H9',
  link: 'M10 13a5 5 0 0 0 7 0l2.5-2.5a5 5 0 0 0-7-7L11 5.5 M14 11a5 5 0 0 0-7 0L4.5 13.5a5 5 0 0 0 7 7L13 19',
  copy: 'M9 9h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2z M5 15V5a2 2 0 0 1 2-2h8',
  folder: 'M3 7a2 2 0 0 1 2-2h4l2 2.2h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z',
  shield: 'M12 3l7.5 3v5.4c0 4.7-3.2 8.4-7.5 10.1C7.7 19.8 4.5 16.1 4.5 11.4V6L12 3z',
  check: 'M8.5 12.5l2.5 2.5 5-5.5',
  download: 'M12 4v10 M8 10.5l4 4 4-4 M5 19h14',
  clipboard: 'M9 4h6a1 1 0 0 1 1 1v1H8V5a1 1 0 0 1 1-1z M8 6H6a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V7a1 1 0 0 0-1-1h-2',
  x: 'M6 6l12 12 M18 6L6 18',
  bolt: 'M13 3L5 13h5l-1 8 8-11h-5l1-7z',
  chevR: 'M9 6l6 6-6 6',
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14z M20 20l-4.2-4.2',
  pulse: 'M3 12h4l2.5-7 4 14 2.5-7h5',
  globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M3 12h18 M12 3c2.5 2.5 3.8 5.6 3.8 9s-1.3 6.5-3.8 9c-2.5-2.5-3.8-5.6-3.8-9S9.5 5.5 12 3z',
  dots: 'M5 12h.01 M12 12h.01 M19 12h.01',
  stack: 'M12 3l8 4.5-8 4.5-8-4.5L12 3z M4 12l8 4.5 8-4.5 M4 16.5l8 4.5 8-4.5',
};

function Icon({ d, size = 15, sw = 1.6, fill = 'none', color = 'currentColor', style }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={fill === 'solid' ? color : 'none'}
      stroke={fill === 'solid' ? 'none' : color} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round"
      style={{ display: 'block', flexShrink: 0, ...style }}>
      {(P[d] || d).split(' M').map((seg, i) => <path key={i} d={(i ? 'M' : '') + seg} />)}
    </svg>
  );
}

// Solid filled glyphs (pause/play/etc.)
function GlyphPause({ size = 13, color = 'currentColor' }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill={color} style={{ display: 'block' }}><rect x="6.5" y="5" width="3.6" height="14" rx="1.2"/><rect x="13.9" y="5" width="3.6" height="14" rx="1.2"/></svg>;
}
function GlyphPlay({ size = 13, color = T.green }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill={color} style={{ display: 'block' }}><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10-6.5a1 1 0 0 0 0-1.72l-10-6.5A1 1 0 0 0 8 5.5z"/></svg>;
}
function GlyphTrash({ size = 13, color = 'currentColor' }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" style={{ display: 'block' }}><path d="M4 7h16 M9 7V4.5h6V7 M6.5 7l1 12.5h9l1-12.5"/></svg>;
}

// ── The goh mark — italic serif "g" + phosphor arrow. Doubles as the menu
// bar status icon and the in-popover identity tile. `state` drives the arrow.
function GohArrow({ w = 13, color = T.green, op = 1 }) {
  // geometric arrow: shaft + head, pointing right
  return (
    <svg width={w} height={w * 0.66} viewBox="0 0 26 17" style={{ display: 'block', opacity: op }}>
      <path d="M1 8.5h17 M14 2.5l9 6-9 6" fill="none" stroke={color} strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
}

function AppGlyph({ size = 22, state = 'active', radius = 0.32, bare = false }) {
  if (bare) return <GlyphG size={size} state={state} />;
  return (
    <span style={{
      width: size, height: size, borderRadius: size * 0.28,
      background: T.ground, display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      boxShadow: `inset 0 0 0 0.5px ${T.hair}, 0 1px 2px rgba(0,0,0,0.4)`, flexShrink: 0,
    }}><GlyphG size={size * 0.72} state={state} /></span>
  );
}

// ── Authentic wordmark, traced from assets/brand/wordmark/goh-wordmark.svg,
// recolored to the locked palette. Arrow is a solid geometric form passing
// THROUGH the o's counter (drawn first, so the letters paint over its tail
// and it reads only inside the o). evenodd fill carries the counters.
const ARROW_PTS = '154,172 243,172 238,161 282,178 238,195 243,184 153,184';
const LETTERS_D = "M 378.500 26.626 C 373.550 28.481, 363.762 31.899, 356.750 34.221 C 349.738 36.543, 344 38.743, 344 39.110 C 344 39.477, 345.462 40.054, 347.250 40.392 C 352.763 41.434, 356.978 44.711, 359.318 49.777 L 361.500 54.500 361.500 143 L 361.500 231.500 359.661 236.267 C 357.646 241.490, 353.674 245.056, 347.764 246.949 C 345.709 247.607, 343.788 248.534, 343.495 249.009 C 342.517 250.591, 351.267 251.024, 378.917 250.761 C 396.320 250.595, 406.457 250.130, 406.671 249.486 C 406.857 248.929, 404.665 247.640, 401.799 246.622 C 398.934 245.605, 395.416 243.515, 393.981 241.980 C 392.546 240.444, 390.839 237.406, 390.186 235.228 C 389.347 232.427, 389.002 218.133, 389.007 186.384 L 389.013 141.500 390.976 138.522 C 394.947 132.497, 402.527 125.850, 408.948 122.762 C 414.442 120.119, 416.953 119.546, 424.500 119.210 C 431.870 118.883, 434.505 119.189, 439.049 120.902 C 442.297 122.126, 446.332 124.710, 448.778 127.131 C 451.141 129.471, 453.944 133.709, 455.228 136.884 L 457.500 142.500 457.500 187 L 457.500 231.500 455.661 236.267 C 453.568 241.690, 449.525 245.207, 443.250 247.061 C 440.913 247.751, 439 248.639, 439 249.033 C 439 250.622, 446.812 251.045, 474.746 250.969 C 498.344 250.906, 504 250.634, 504 249.564 C 504 248.819, 501.950 247.721, 499.324 247.060 C 493.513 245.597, 487.652 240.013, 486.115 234.477 C 485.387 231.854, 485.009 215.487, 485.006 186.386 C 485.002 161.302, 484.569 139.949, 484.001 136.886 C 482.522 128.910, 476.680 117.749, 471.722 113.430 C 465.995 108.441, 456.878 104.302, 448.826 103.035 C 441.412 101.870, 431.467 102.864, 423.328 105.585 C 412.937 109.059, 402.218 116.673, 393.750 126.596 L 389 132.162 389 78.140 C 389 48.428, 388.663 23.923, 388.250 23.685 C 387.837 23.447, 383.450 24.771, 378.500 26.626 M 88.679 103.009 C 79.735 104.110, 68.955 107.415, 61.506 111.341 C 53.973 115.311, 43.064 125.929, 39.723 132.543 C 33.262 145.336, 31.862 159.962, 35.953 171.946 C 39.872 183.428, 47.964 193.378, 58.313 199.443 C 60.891 200.954, 63 202.526, 63 202.936 C 63 203.346, 60.647 204.963, 57.771 206.528 C 54.895 208.094, 49.987 211.878, 46.864 214.937 C 40.915 220.767, 39.016 224.957, 39.006 232.282 C 38.994 239.836, 44.125 247.500, 51.804 251.403 L 56.353 253.715 48.074 258.022 C 43.521 260.391, 37.569 264.497, 34.849 267.147 C 32.129 269.796, 28.917 274.110, 27.711 276.732 C 26.001 280.454, 25.520 283.365, 25.522 290 C 25.524 296.925, 25.947 299.296, 27.805 302.795 C 29.060 305.157, 31.693 308.868, 33.656 311.041 C 49.137 328.176, 91.827 335.649, 125.242 327.073 C 141.763 322.833, 152.845 316.939, 163.168 306.903 C 168.158 302.052, 170.881 298.349, 173.461 292.903 C 175.391 288.832, 177.440 283.025, 178.016 280 C 179.265 273.434, 178.453 265.417, 175.818 258.298 C 174.759 255.437, 171.920 250.903, 169.509 248.221 C 167.098 245.539, 162.426 241.907, 159.127 240.148 C 155.827 238.390, 149.612 236.023, 145.314 234.890 C 138.436 233.076, 133.247 232.746, 102 232.139 C 71.014 231.537, 66.089 231.228, 63.267 229.708 C 61.489 228.750, 59.302 226.551, 58.407 224.821 C 57.075 222.243, 56.982 221.002, 57.898 217.947 C 59.112 213.893, 65.523 207.409, 69.238 206.476 C 70.497 206.161, 74.220 206.642, 77.513 207.546 C 80.806 208.451, 88.039 209.429, 93.586 209.719 C 107.204 210.433, 117.701 208.332, 129.500 202.531 C 134.450 200.098, 140.813 196.066, 143.641 193.571 C 149.872 188.074, 155.824 179.347, 158.150 172.298 C 159.096 169.429, 160.163 164.025, 160.521 160.290 C 161.705 147.915, 156.799 132.647, 148.940 124.250 L 145.899 121 155.205 121 L 164.511 121 171.102 112.750 L 177.693 104.500 164.697 104.220 L 151.700 103.940 147.100 107.729 C 138.376 114.915, 139.747 114.640, 132.249 110.701 C 119.927 104.229, 103.022 101.244, 88.679 103.009 M 254.500 103.061 C 235.032 104.981, 215.815 115.024, 203.910 129.500 C 197.802 136.927, 191.683 148.523, 189.586 156.644 C 188.714 160.024, 188 163.061, 188 163.394 C 188 163.727, 194.741 164, 202.981 164 L 217.962 164 218.382 161.750 C 220.554 150.131, 222.828 142.577, 226.158 135.925 C 231.437 125.378, 238.396 117.914, 246.813 113.774 L 253.469 110.500 263.984 110.500 L 274.500 110.500 280.792 113.912 C 284.391 115.863, 289.411 119.837, 292.521 123.196 C 298.680 129.848, 303.791 139.711, 307.189 151.500 C 309.244 158.632, 309.490 161.562, 309.452 178.500 L 309.410 197.500 306.698 206.288 C 303.116 217.899, 298.220 227.427, 292.658 233.613 C 290.165 236.386, 285.510 240.037, 282.313 241.726 C 268.366 249.096, 254.270 248.265, 241.178 239.302 C 235.581 235.469, 228.344 226.294, 225.060 218.866 C 223.039 214.296, 219.616 202.159, 218.539 195.750 L 217.909 192 202.909 192 L 187.909 192 188.604 195.750 C 189.753 201.951, 192.785 209.924, 196.568 216.689 C 200.598 223.895, 210.294 234.730, 216.586 239.059 C 223.384 243.737, 234.078 248.738, 241.941 250.917 C 251.664 253.611, 264.626 254.478, 274.439 253.090 C 284.192 251.711, 297.115 247.351, 304.749 242.865 C 307.898 241.014, 314.344 235.674, 319.071 230.997 C 326.264 223.883, 328.429 220.945, 332.333 212.997 C 339.107 199.207, 340.486 193.091, 340.451 177 L 340.421 163.500 337.164 154.054 C 335.373 148.859, 332.288 141.944, 330.310 138.688 C 325.306 130.449, 316.045 120.848, 307.844 115.396 C 304.033 112.862, 296.771 109.309, 291.707 107.500 C 286.562 105.662, 278.530 103.724, 273.500 103.108 C 268.550 102.502, 264.050 102.066, 263.500 102.139 C 262.950 102.212, 258.900 102.628, 254.500 103.061 M 89.734 110.027 C 76.850 113.272, 68.483 122.555, 64.284 138.265 C 61.962 146.955, 62.030 166.410, 64.411 174.500 C 68.186 187.324, 74.240 195.398, 84 200.625 C 86.753 202.100, 89.635 202.500, 97.500 202.500 L 107.500 202.500 112.819 199.554 C 115.744 197.933, 119.458 195.104, 121.071 193.267 C 125.024 188.765, 128.705 181.285, 130.683 173.735 C 132.871 165.385, 132.863 147.587, 130.669 139.210 C 128.365 130.416, 124.637 122.962, 120.316 118.514 C 118.291 116.428, 114.285 113.646, 111.414 112.332 C 105.518 109.633, 95.520 108.570, 89.734 110.027 M 59 258.453 C 49.473 265.541, 45.115 276.787, 47.099 289.165 C 47.658 292.649, 49.291 297.512, 50.729 299.971 C 54.475 306.378, 62.075 313.273, 69.277 316.798 C 78.891 321.505, 87.025 323.246, 99.500 323.266 C 107.791 323.280, 112.462 322.743, 118.465 321.086 C 122.846 319.877, 129.133 317.451, 132.437 315.694 C 135.741 313.937, 140.734 310.213, 143.533 307.417 C 150.413 300.546, 153.270 294.361, 153.801 285.189 C 154.340 275.884, 152.355 270.316, 146.805 265.565 C 139.354 259.188, 136.953 258.778, 102 257.921 C 84.675 257.496, 68.700 256.856, 66.500 256.499 C 63.153 255.955, 61.928 256.274, 59 258.453";
// only the g's three subpaths (outer body, counter hole, descender loop)
const G_D = LETTERS_D.split(/(?=M )/).filter((s) => /^M (88\.679|89\.734|59 )/.test(s)).join(' ');

// Full goh wordmark, recolored. arrow=true shows the phosphor arrow.
function WordmarkGoh({ h = 26, type = T.type, accent = T.green, arrow = true }) {
  const w = h * (530 / 350);
  return (
    <svg height={h} width={w} viewBox="0 0 530 350" style={{ display: 'block', overflow: 'visible' }}>
      {arrow && <polygon points={ARROW_PTS} fill={accent} />}
      <path d={LETTERS_D} fill={type} fillRule="evenodd" />
    </svg>
  );
}

// A small Liquid-Glass tile bearing the full goh wordmark — the tray icon / header mark.
// `active` brightens the tile (popover open / drag-over); `state` drives the arrow color.
function GohWordmarkTile({ h = 18, light = false, state = 'active', active = false }) {
  const type = light ? '#1b1813' : '#F4EDE0';
  const accent = state === 'error' ? T.oxblood
    : state === 'paused' ? (light ? 'rgba(27,24,19,0.45)' : 'rgba(244,237,224,0.5)')
    : T.green;
  const showArrow = state !== 'idle';
  const idleBg = light ? 'rgba(255,255,255,0.4)' : 'rgba(255,255,255,0.1)';
  const activeBg = light ? 'rgba(11,122,67,0.16)' : 'rgba(107,250,155,0.18)';
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      height: h, padding: `0 ${Math.round(h * 0.26)}px`, borderRadius: Math.round(h * 0.34),
      background: active ? activeBg : idleBg,
      backdropFilter: 'blur(12px) saturate(170%)', WebkitBackdropFilter: 'blur(12px) saturate(170%)',
      boxShadow: `inset 0 0.6px 0 rgba(255,255,255,${light ? 0.85 : 0.3}), inset 0 0 0 0.5px rgba(${light ? '0,0,0' : '255,255,255'},0.14)`,
      transition: 'background .15s',
    }}>
      <WordmarkGoh h={Math.round(h * 0.72)} type={type} accent={accent} arrow={showArrow} />
    </span>
  );
}

// The g glyph alone + arrow in the right portion — the app/menubar icon (§5/§6).
function GlyphG({ size = 18, state = 'active', type = T.type, accent = T.green, bad = T.oxblood, dimArrow = 'rgba(244,237,224,0.5)' }) {
  const showArrow = ['active', 'done', 'paused', 'error'].includes(state);
  const arrowCol = state === 'error' ? bad : state === 'paused' ? dimArrow : accent;
  const vw = showArrow ? 272 : 176;
  const h = 244;
  const w = size * (vw / h);
  return (
    <svg height={size} width={w} viewBox={`20 94 ${vw} ${h}`} style={{ display: 'block', overflow: 'visible' }}>
      {showArrow && <polygon points={ARROW_PTS} fill={arrowCol} />}
      <path d={G_D} fill={type} fillRule="evenodd" />
    </svg>
  );
}

// ── Menu bar scene: dark desktop + top bar with the goh status item.
function MenuBarScene({ children, glyphState = 'active', clock = '9:41 AM', width, height }) {
  return (
    <div style={{
      width, height, position: 'relative', overflow: 'hidden',
      fontFamily: FONT.ui, color: T.type,
      background: `
        radial-gradient(130% 80% at 82% -8%, #213244 0%, rgba(33,50,68,0) 52%),
        radial-gradient(95% 70% at 0% 108%, #2b2540 0%, rgba(43,37,64,0) 50%),
        linear-gradient(165deg, #11141b 0%, #0b0d12 58%, #08090d 100%)`,
    }}>
      {/* desktop grain */}
      <div style={{ position: 'absolute', inset: 0, opacity: 0.5, pointerEvents: 'none',
        backgroundImage: `radial-gradient(rgba(255,255,255,0.018) 1px, transparent 1px)`, backgroundSize: '3px 3px' }} />
      {/* menu bar */}
      <div style={{
        position: 'absolute', top: 0, left: 0, right: 0, height: 26,
        display: 'flex', alignItems: 'center', padding: '0 9px 0 12px',
        background: 'rgba(14,16,22,0.55)',
        backdropFilter: 'blur(40px) saturate(150%)', WebkitBackdropFilter: 'blur(40px) saturate(150%)',
        borderBottom: `0.5px solid rgba(255,255,255,0.07)`, zIndex: 5,
      }}>
        <span style={{ fontSize: 13.5, fontWeight: 700, fontStyle: 'italic', fontFamily: FONT.serif, marginRight: 18 }}>goh</span>
        {['File', 'Edit', 'View', 'Window', 'Help'].map((m) => (
          <span key={m} style={{ fontSize: 13, opacity: 0.84, marginRight: 16 }}>{m}</span>
        ))}
        <span style={{ flex: 1 }} />
        <span style={{ display: 'flex', alignItems: 'center', gap: 15, whiteSpace: 'nowrap', flexShrink: 0 }}>
          <Icon d="M9 18V5l8-2v13 M9 9l8-2" size={13} sw={1.5} color="rgba(244,237,224,0.8)" />
          <Icon d={P.search} size={13} sw={1.6} color="rgba(244,237,224,0.8)" />
          <span style={{ display: 'inline-flex', alignItems: 'center', padding: '2px 5px', borderRadius: 5, background: 'rgba(255,255,255,0.10)', boxShadow: `inset 0 0 0 0.5px ${T.hair}` }}>
            <AppGlyph size={16} state={glyphState} bare />
          </span>
          <span style={{ fontSize: 13, fontFamily: FONT.mono, fontWeight: 500, letterSpacing: '0.01em', opacity: 0.9 }}>{clock}</span>
        </span>
      </div>
      {children}
    </div>
  );
}

// Popover shell with the notch — anchored under the status item (right side).
function Popover({ width = 372, children, right = 16, notchRight = 50 }) {
  const c = useTheme();
  return (
    <div style={{ position: 'absolute', top: 31, right, zIndex: 4 }}>
      <div style={{ position: 'absolute', top: -6, right: notchRight, width: 14, height: 7, overflow: 'hidden' }}>
        <div style={{ position: 'absolute', top: 2.5, left: 1, width: 11, height: 11, transform: 'rotate(45deg)',
          background: c.notch, backdropFilter: 'blur(72px) saturate(185%)', WebkitBackdropFilter: 'blur(72px) saturate(185%)', boxShadow: `inset 0 0 0 0.5px ${c.hair}` }} />
      </div>
      <div style={{
        width, borderRadius: 14, overflow: 'hidden',
        background: c.popBg,
        backdropFilter: 'blur(72px) saturate(185%)', WebkitBackdropFilter: 'blur(72px) saturate(185%)',
        boxShadow: `inset 0 0 0 0.5px ${c.hair}, inset 0 1px 0 ${c.topHi}, ${c.shadow}`,
      }}>{children}</div>
    </div>
  );
}

// ── Shared sample data ─────────────────────────────────────────────────────
const AGG = { active: 2, speed: '6.4 MB/s', conns: 12, queued: 1 };
const JOBS = [
  { id: 1, name: 'llama-3.1-70b-instruct.safetensors', state: 'active', pct: 62, speed: '5.1 MB/s', done: '42.6', total: '68.4 GB', eta: '1m 12s', conns: 8, host: 'huggingface.co' },
  { id: 2, name: 'imagenet-val.tar.zst', state: 'active', pct: 28, speed: '1.3 MB/s', done: '1.79', total: '6.40 GB', eta: '4m 03s', conns: 4, host: 'image-net.org' },
  { id: 3, name: 'tokenizer.model', state: 'paused', pct: 44, speed: null, done: '0.9', total: '2.1 MB', eta: null, conns: 0, host: 'huggingface.co' },
  { id: 4, name: 'dataset-shard-00007.parquet', state: 'queued', pct: 0, speed: null, done: '0', total: '512 MB', eta: null, conns: 0, host: 'data.example.com' },
  { id: 5, name: 'sd-xl-base-1.0.safetensors', state: 'completed', pct: 100, done: '6.94', total: '6.94 GB', host: 'huggingface.co', sha: 'a1f3…9c20', verified: 'Jun 5' },
  { id: 6, name: 'config.json', state: 'completed', pct: 100, done: '4.2', total: '4.2 KB', host: 'huggingface.co', sha: '77be…01da', verified: 'Jun 5' },
  { id: 7, name: 'vocab.bpe', state: 'failed', pct: 73, done: '0.7', total: '1.0 MB', host: 'cdn.example.com' },
];

const STATE_META = {
  active:    { label: 'Active',    color: T.green },
  paused:    { label: 'Paused',    color: T.dim },
  queued:    { label: 'Queued',    color: T.faint },
  completed: { label: 'Completed', color: T.dim },
  failed:    { label: 'Failed',    color: T.oxblood },
};

// split a filename into stem + extension for mono-tail treatment
function splitName(name) {
  const i = name.lastIndexOf('.');
  if (i <= 0) return [name, ''];
  return [name.slice(0, i), name.slice(i)];
}

// ── Thin progress track (green fill = live) ────────────────────────────────
function Track({ pct = 0, state = 'active', h = 3, animated = true, radius = 2 }) {
  const c = useTheme();
  const live = state === 'active';
  const col = state === 'failed' ? c.oxblood : state === 'paused' ? c.dim : c.green;
  return (
    <div style={{ position: 'relative', height: h, borderRadius: radius, background: c.track, overflow: 'hidden' }}>
      <div style={{
        position: 'absolute', inset: 0, width: `${pct}%`, borderRadius: radius,
        background: col,
        boxShadow: live && c.glow ? `0 0 8px ${c.greenDim}` : 'none',
      }}>
        {live && animated && (
          <div style={{ position: 'absolute', top: 0, bottom: 0, width: '40%',
            background: 'linear-gradient(90deg, transparent, rgba(255,255,255,0.45), transparent)',
            animation: 'gohShimmer 2.2s linear infinite' }} />
        )}
      </div>
    </div>
  );
}

// Small hover-able control button
function Ctrl({ children, title, danger, onClick }) {
  const c = useTheme();
  const [h, setH] = useState(false);
  return (
    <button className="goh-btn" title={title} onClick={onClick}
      onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{
        width: 23, height: 23, borderRadius: 6, border: 'none', cursor: 'pointer', padding: 0,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: h ? c.fillH : 'transparent',
        color: danger ? c.oxblood : (h ? c.type : c.dim),
      }}>{children}</button>
  );
}

Object.assign(window, {
  T, FONT, Icon, P, GlyphPause, GlyphPlay, GlyphTrash, GohArrow, AppGlyph, WordmarkGoh, GohWordmarkTile, GlyphG,
  MenuBarScene, Popover, AGG, JOBS, STATE_META, splitName, Track, Ctrl,
  ARROW_PTS, LETTERS_D, G_D, PALETTE, useTheme, ThemeProvider,
  useState, useEffect, useRef,
});
