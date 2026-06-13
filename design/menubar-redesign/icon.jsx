/* icon.jsx — goh macOS app-icon studio: treatments, size ramp, dock context */
/* eslint-disable */
const { useState: useIS } = React;

// Apple-style continuous-curvature squircle (superellipse) path for a size×size box.
function squircle(size, n = 5) {
  const a = size / 2, c = size / 2, N = 160;
  let d = '';
  for (let i = 0; i <= N; i++) {
    const t = (i / N) * 2 * Math.PI;
    const ct = Math.cos(t), st = Math.sin(t);
    const x = c + a * Math.sign(ct) * Math.pow(Math.abs(ct), 2 / n);
    const y = c + a * Math.sign(st) * Math.pow(Math.abs(st), 2 / n);
    d += (i ? 'L' : 'M') + x.toFixed(2) + ' ' + y.toFixed(2) + ' ';
  }
  return d + 'Z';
}

// One icon tile. treatment ∈ phosphor | glass | paper. Glyph drawn via nested SVG
// (auto-scales the authentic g+arrow into the tile), so it stays crisp at any size.
function IconTile({ size = 200, treatment = 'phosphor', glow = true, mode = 'mark' }) {
  const uid = treatment + size + mode;
  const sq = squircle(size);
  const mark = mode !== 'wordmark';
  const gw = size * (mark ? 0.60 : 0.82);
  const gh = mark ? gw * (244 / 272) : gw * (350 / 530);
  const gx = (size - gw) / 2, gy = (size - gh) / 2 + size * (mark ? 0.012 : 0);

  const T_ = {
    phosphor: { type: '#F4EDE0', accent: '#6BFA9B', glow: '#6BFA9B' },
    glass:    { type: '#0e2b1c', accent: '#0B7A43', glow: null },
    paper:    { type: '#15140E', accent: '#1E8A52', glow: null },
  }[treatment];

  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ display: 'block', overflow: 'visible' }}>
      <defs>
        <linearGradient id={`bg-${uid}`} x1="0" y1="0" x2="0" y2="1">
          {treatment === 'phosphor' && <><stop offset="0" stopColor="#1c2436" /><stop offset="0.5" stopColor="#0f1422" /><stop offset="1" stopColor="#080a10" /></>}
          {treatment === 'glass' && <><stop offset="0" stopColor="#eef7f1" /><stop offset="0.5" stopColor="#d6efe0" /><stop offset="1" stopColor="#bfe6cf" /></>}
          {treatment === 'paper' && <><stop offset="0" stopColor="#FDFAF5" /><stop offset="1" stopColor="#EFE7D7" /></>}
        </linearGradient>
        <radialGradient id={`sheen-${uid}`} cx="0.5" cy="0" r="0.9">
          <stop offset="0" stopColor="#ffffff" stopOpacity={treatment === 'phosphor' ? 0.16 : 0.6} />
          <stop offset="0.55" stopColor="#ffffff" stopOpacity="0" />
        </radialGradient>
        <clipPath id={`clip-${uid}`}><path d={sq} /></clipPath>
        {glow && treatment === 'phosphor' && (
          <filter id={`glow-${uid}`} x="-40%" y="-40%" width="180%" height="180%">
            <feGaussianBlur stdDeviation={size * 0.012} result="b" />
            <feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
          </filter>
        )}
      </defs>

      {/* base */}
      <path d={sq} fill={`url(#bg-${uid})`} />
      {/* top sheen + bottom depth, clipped to the squircle */}
      <g clipPath={`url(#clip-${uid})`}>
        <rect x="0" y="0" width={size} height={size * 0.62} fill={`url(#sheen-${uid})`} />
        <rect x="0" y={size * 0.72} width={size} height={size * 0.28} fill="#000" opacity={treatment === 'phosphor' ? 0.18 : 0.06} />
      </g>
      {/* rim */}
      <path d={sq} fill="none" stroke={treatment === 'phosphor' ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.08)'} strokeWidth={Math.max(1, size * 0.004)} />
      <path d={sq} fill="none" stroke="rgba(255,255,255,0.5)" strokeWidth={Math.max(0.5, size * 0.0025)} strokeOpacity={treatment === 'phosphor' ? 0.06 : 0.5} transform={`translate(0 ${size * 0.004})`} clipPath={`url(#clip-${uid})`} />

      {/* the authentic mark (g+arrow) or full wordmark (goh) */}
      <svg x={gx} y={gy} width={gw} height={gh} viewBox={mark ? '20 94 272 244' : '0 0 530 350'} filter={glow && treatment === 'phosphor' ? `url(#glow-${uid})` : undefined}>
        <polygon points={ARROW_PTS} fill={T_.accent} />
        <path d={mark ? G_D : LETTERS_D} fill={T_.type} fillRule="evenodd" />
      </svg>
    </svg>
  );
}

const FLOAT = { filter: 'drop-shadow(0 18px 32px rgba(0,0,0,0.45)) drop-shadow(0 4px 10px rgba(0,0,0,0.3))' };

function Treatment({ treatment, label, sub, primary, mode }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16 }}>
      <div style={FLOAT}><IconTile size={200} treatment={treatment} mode={mode} /></div>
      <div style={{ textAlign: 'center' }}>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, fontSize: 15, fontWeight: 600, color: '#F4EDE0' }}>
          {label}
          {primary && <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.06em', color: '#6BFA9B', border: '1px solid rgba(107,250,155,0.4)', borderRadius: 5, padding: '1px 6px' }}>RECOMMENDED</span>}
        </div>
        <div style={{ fontSize: 12.5, color: 'rgba(244,237,224,0.5)', marginTop: 4, maxWidth: 200, lineHeight: 1.4 }}>{sub}</div>
      </div>
    </div>
  );
}

function SizeRamp({ treatment, mode }) {
  const sizes = [128, 64, 32, 16];
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', gap: 28 }}>
      {sizes.map((s) => (
        <div key={s} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 9 }}>
          <div style={{ filter: 'drop-shadow(0 4px 10px rgba(0,0,0,0.4))' }}><IconTile size={s} treatment={treatment} glow={s >= 32} mode={mode} /></div>
          <span style={{ fontFamily: '"JetBrains Mono", monospace', fontSize: 10.5, color: 'rgba(244,237,224,0.42)' }}>{s}px</span>
        </div>
      ))}
    </div>
  );
}

// macOS Dock mockup for context
function Dock({ treatment, mode }) {
  const SysIcon = ({ from, to, children }) => (
    <div style={{ width: 56, height: 56, borderRadius: 13, background: `linear-gradient(160deg, ${from}, ${to})`, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.25), 0 4px 10px rgba(0,0,0,0.3)', flexShrink: 0 }}>{children}</div>
  );
  return (
    <div style={{ display: 'inline-flex', alignItems: 'flex-end', gap: 12, padding: '10px 14px', borderRadius: 22,
      background: 'rgba(255,255,255,0.12)', backdropFilter: 'blur(30px) saturate(160%)', WebkitBackdropFilter: 'blur(30px) saturate(160%)',
      boxShadow: 'inset 0 0 0 0.5px rgba(255,255,255,0.2), 0 18px 50px rgba(0,0,0,0.45)' }}>
      <SysIcon from="#3a3a3c" to="#1c1c1e"><span style={{ color: '#fff', fontSize: 24 }}>􀈕</span></SysIcon>
      <SysIcon from="#4aa3ff" to="#0a6cff"><span style={{ color: '#fff', fontSize: 26, fontWeight: 700 }}>S</span></SysIcon>
      <SysIcon from="#6dd66d" to="#1ea64a"><span style={{ color: '#fff', fontSize: 24 }}>􀦃</span></SysIcon>
      {/* goh, slightly raised as if hovered */}
      <div style={{ transform: 'translateY(-10px)', filter: 'drop-shadow(0 10px 16px rgba(0,0,0,0.4))' }}>
        <IconTile size={64} treatment={treatment} mode={mode} />
        <div style={{ width: 4, height: 4, borderRadius: 3, background: 'rgba(255,255,255,0.7)', margin: '6px auto 0' }} />
      </div>
      <SysIcon from="#ff9f6a" to="#ff5e3a"><span style={{ color: '#fff', fontSize: 24 }}>􀍟</span></SysIcon>
      <SysIcon from="#b06dff" to="#7b2ff7"><span style={{ color: '#fff', fontSize: 24 }}>􀪥</span></SysIcon>
    </div>
  );
}

function Swatch({ c, label }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <span style={{ width: 16, height: 16, borderRadius: 4, background: c, boxShadow: 'inset 0 0 0 0.5px rgba(255,255,255,0.18)' }} />
      <span style={{ fontFamily: FONT.mono, fontSize: 11.5, color: 'rgba(244,237,224,0.62)' }}>{label}</span>
    </div>
  );
}

function IconStudio() {
  return (
    <div style={{ minHeight: '100vh', boxSizing: 'border-box', padding: '56px 40px 70px',
      fontFamily: FONT.ui, color: '#F4EDE0',
      background: 'radial-gradient(120% 90% at 80% -10%, #243748 0%, rgba(36,55,72,0) 52%), radial-gradient(95% 70% at 0% 110%, #2c2542 0%, rgba(44,37,66,0) 50%), linear-gradient(165deg, #12151c 0%, #0a0c11 100%)' }}>
      <div style={{ maxWidth: 920, margin: '0 auto' }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 6 }}>
          <span style={{ fontFamily: FONT.serif, fontStyle: 'italic', fontWeight: 700, fontSize: 30 }}>goh</span>
          <span style={{ fontFamily: FONT.mono, fontSize: 11, letterSpacing: '0.14em', color: 'rgba(244,237,224,0.5)', textTransform: 'uppercase' }}>App Icon</span>
          <span style={{ fontFamily: FONT.mono, fontSize: 10, fontWeight: 700, letterSpacing: '0.08em', color: '#6BFA9B', border: '1px solid rgba(107,250,155,0.4)', borderRadius: 5, padding: '2px 7px' }}>FINAL</span>
        </div>
        <div style={{ fontSize: 14, color: 'rgba(244,237,224,0.55)', marginBottom: 44, maxWidth: 580, lineHeight: 1.5 }}>
          Full <span style={{ fontFamily: FONT.serif, fontStyle: 'italic' }}>goh</span> wordmark, Phosphor treatment, on Apple’s continuous-curvature squircle — the phosphor arrow runs through the <span style={{ fontFamily: FONT.serif, fontStyle: 'italic' }}>o</span>.
        </div>

        {/* hero */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 54, flexWrap: 'wrap', marginBottom: 56 }}>
          <div style={FLOAT}><IconTile size={272} treatment="phosphor" mode="wordmark" /></div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            <div style={{ fontSize: 17, fontWeight: 600 }}>goh</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <Swatch c="linear-gradient(160deg,#1c2436,#080a10)" label="Ground · #0C0E14" />
              <Swatch c="#F4EDE0" label="Letters · #F4EDE0" />
              <Swatch c="#6BFA9B" label="Arrow · #6BFA9B" />
            </div>
            <div style={{ fontFamily: FONT.mono, fontSize: 11, color: 'rgba(244,237,224,0.4)', lineHeight: 1.6, marginTop: 4 }}>
              squircle · superellipse n≈5<br />render 16→1024 @1×/@2× · Icon Composer
            </div>
          </div>
        </div>

        {/* size ramp + dock */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 40, borderTop: '0.5px solid rgba(255,255,255,0.1)', paddingTop: 40 }}>
          <div>
            <div style={{ fontFamily: FONT.mono, fontSize: 10.5, letterSpacing: '0.14em', color: 'rgba(244,237,224,0.4)', textTransform: 'uppercase', marginBottom: 20 }}>Size ramp — legibility down to 16px</div>
            <SizeRamp treatment="phosphor" mode="wordmark" />
          </div>
          <div>
            <div style={{ fontFamily: FONT.mono, fontSize: 10.5, letterSpacing: '0.14em', color: 'rgba(244,237,224,0.4)', textTransform: 'uppercase', marginBottom: 20 }}>In the Dock</div>
            <Dock treatment="phosphor" mode="wordmark" />
          </div>
          <div>
            <div style={{ fontFamily: FONT.mono, fontSize: 10.5, letterSpacing: '0.14em', color: 'rgba(244,237,224,0.4)', textTransform: 'uppercase', marginBottom: 20 }}>Alternate treatments</div>
            <div style={{ display: 'flex', gap: 34, alignItems: 'flex-start' }}>
              {[['glass', 'Liquid Glass'], ['paper', 'Paper'], ['phosphor', 'Phosphor · g+arrow']].map(([t, l], i) => (
                <div key={l} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10 }}>
                  <div style={{ filter: 'drop-shadow(0 8px 16px rgba(0,0,0,0.4))' }}><IconTile size={84} treatment={t} mode={i === 2 ? 'mark' : 'wordmark'} /></div>
                  <span style={{ fontSize: 11.5, color: 'rgba(244,237,224,0.5)' }}>{l}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<IconStudio />);
