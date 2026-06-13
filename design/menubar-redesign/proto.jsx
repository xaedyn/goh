/* proto.jsx — interactive, tweakable Manifest prototype in a live menu-bar scene */
/* eslint-disable */

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "surface": "popover",
  "scenario": "busy",
  "daemon": "connected",
  "iconState": "auto",
  "appearance": "dark",
  "density": "comfortable",
  "reduceMotion": false
}/*EDITMODE-END*/;

const SCN = {
  busy: JOBS,
  light: [
    { id: 1, name: 'mistral-7b-v0.3.safetensors', state: 'active', pct: 81, speed: '7.2 MB/s', done: '11.8', total: '14.5 GB', eta: '37s', conns: 8, host: 'huggingface.co' },
    { id: 5, name: 'sd-xl-base-1.0.safetensors', state: 'completed', pct: 100, done: '6.94', total: '6.94 GB', host: 'huggingface.co', sha: 'a1f3…9c20', verified: 'Jun 5' },
    { id: 6, name: 'config.json', state: 'completed', pct: 100, done: '4.2', total: '4.2 KB', host: 'huggingface.co', sha: '77be…01da', verified: 'Jun 5' },
  ],
  empty: [],
};

function deriveIcon(scenario, daemon) {
  if (daemon === 'failed') return 'error';
  if (daemon === 'reconnecting') return 'paused';
  const jobs = SCN[scenario] || [];
  if (jobs.some((j) => j.state === 'active')) return 'active';
  if (jobs.some((j) => j.state === 'paused')) return 'paused';
  return 'idle';
}

const WALL = {
  dark: `radial-gradient(130% 80% at 82% -8%, #213244 0%, rgba(33,50,68,0) 52%),
         radial-gradient(95% 70% at 0% 108%, #2b2540 0%, rgba(43,37,64,0) 50%),
         linear-gradient(165deg, #11141b 0%, #0b0d12 58%, #08090d 100%)`,
  light: `radial-gradient(120% 80% at 80% -10%, #f3ece0 0%, rgba(243,236,224,0) 55%),
          radial-gradient(90% 70% at 0% 110%, #e7dceb 0%, rgba(231,220,235,0) 50%),
          linear-gradient(165deg, #e9e3d6 0%, #ddd5c6 60%, #d4cbb9 100%)`,
};

function ProtoScene({ t }) {
  const light = t.appearance === 'light';
  const iconState = t.iconState === 'auto' ? deriveIcon(t.scenario, t.daemon) : t.iconState;
  const barText = light ? '#1b1915' : T.type;
  const barBg = light ? 'rgba(250,248,244,0.62)' : 'rgba(14,16,22,0.55)';
  const barLine = light ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.07)';
  const chipBg = light ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.10)';
  const pal = PALETTE[light ? 'light' : 'dark'];
  const iconType = light ? pal.type : T.type;
  const activeTint = light ? 'rgba(11,122,67,0.16)' : 'rgba(107,250,155,0.12)';
  const open = t.surface === 'popover';
  const openHi = light ? 'rgba(0,0,0,0.12)' : 'rgba(255,255,255,0.26)';

  return (
    <div className={t.reduceMotion ? 'goh-reduce' : ''} style={{ width: 1280, height: 900, position: 'relative', overflow: 'hidden', background: WALL[light ? 'light' : 'dark'], fontFamily: FONT.ui }}>
      <div style={{ position: 'absolute', inset: 0, opacity: 0.5, pointerEvents: 'none', backgroundImage: `radial-gradient(${light ? 'rgba(0,0,0,0.02)' : 'rgba(255,255,255,0.018)'} 1px, transparent 1px)`, backgroundSize: '3px 3px' }} />

      {/* menu bar */}
      <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 26, display: 'flex', alignItems: 'center', padding: '0 9px 0 12px',
        background: barBg, backdropFilter: 'blur(40px) saturate(150%)', WebkitBackdropFilter: 'blur(40px) saturate(150%)', borderBottom: `0.5px solid ${barLine}`, zIndex: 5, color: barText }}>
        <span style={{ fontSize: 13.5, fontWeight: 700, fontStyle: 'italic', fontFamily: FONT.serif, marginRight: 18 }}>goh</span>
        {['File', 'Edit', 'View', 'Window', 'Help'].map((m) => <span key={m} style={{ fontSize: 13, opacity: 0.82, marginRight: 16 }}>{m}</span>)}
        <span style={{ flex: 1 }} />
        <span style={{ display: 'flex', alignItems: 'center', gap: 15, whiteSpace: 'nowrap' }}>
          <Icon d="M9 18V5l8-2v13 M9 9l8-2" size={13} sw={1.5} color={light ? 'rgba(27,25,21,0.8)' : 'rgba(244,237,224,0.8)'} />
          <Icon d={P.search} size={13} sw={1.6} color={light ? 'rgba(27,25,21,0.8)' : 'rgba(244,237,224,0.8)'} />
          <span id="goh-status-item" style={{ display: 'inline-flex', alignItems: 'center', padding: '2px 6px', borderRadius: 6, background: open ? openHi : (iconState === 'active' || iconState === 'done' ? activeTint : chipBg) }}>
            <GlyphG size={16} state={iconState} type={iconType} accent={pal.green} bad={pal.oxblood} dimArrow={pal.dimArrow} />
          </span>
          <span style={{ fontSize: 13, fontFamily: FONT.mono, fontWeight: 500, opacity: 0.9 }}>9:41 AM</span>
        </span>
      </div>

      {/* surface — themed to match the desktop appearance */}
      <ThemeProvider mode={t.appearance}>
        {t.surface === 'popover' && (
          <ManifestPopover jobs={SCN[t.scenario]} daemon={t.daemon} density={t.density} />
        )}
        {t.surface === 'add' && (
          <div style={{ position: 'absolute', top: 70, left: '50%', transform: 'translateX(-50%)' }}><AddDownloadWindow /></div>
        )}
        {t.surface === 'trust' && (
          <div style={{ position: 'absolute', top: 60, left: '50%', transform: 'translateX(-50%)' }}><TrustWindow /></div>
        )}
        {t.surface === 'prefs' && (
          <div style={{ position: 'absolute', top: 66, left: '50%', transform: 'translateX(-50%)' }}><PreferencesWindow /></div>
        )}
      </ThemeProvider>

      {/* caption */}
      <div style={{ position: 'absolute', left: 22, bottom: 20, maxWidth: 300, fontSize: 11.5, lineHeight: 1.5, color: light ? 'rgba(27,25,21,0.5)' : 'rgba(244,237,224,0.4)' }}>
        <span style={{ fontFamily: FONT.serif, fontStyle: 'italic', fontWeight: 700, fontSize: 15, color: light ? 'rgba(27,25,21,0.85)' : 'rgba(244,237,224,0.8)' }}>goh</span>
        <span style={{ marginLeft: 8, fontFamily: FONT.mono, fontSize: 10, letterSpacing: '0.04em' }}>· Manifest · live prototype</span>
        <div style={{ marginTop: 5 }}>Open <b style={{ color: light ? '#1b1915' : T.type }}>Tweaks</b> (top toolbar) to drive daemon, icon, appearance, density &amp; surface.</div>
      </div>
    </div>
  );
}

// Letterbox the fixed 1280×900 desktop scene to fit any viewport.
function Stage({ children }) {
  const [vp, setVp] = useState({ w: window.innerWidth, h: window.innerHeight });
  useEffect(() => {
    const r = () => setVp({ w: window.innerWidth, h: window.innerHeight });
    window.addEventListener('resize', r);
    return () => window.removeEventListener('resize', r);
  }, []);
  const scale = Math.min(vp.w / 1280, vp.h / 900);
  return (
    <div style={{ position: 'fixed', inset: 0, background: '#08090d', overflow: 'hidden', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ width: 1280, height: 900, transform: `scale(${scale})`, transformOrigin: 'center center', flexShrink: 0 }}>
        {children}
      </div>
    </div>
  );
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  return (
    <>
      <Stage><ProtoScene t={t} /></Stage>
      <TweaksPanel title="Tweaks">
        <TweakSection label="Surface" />
        <TweakSelect label="Showing" value={t.surface}
          options={[{ value: 'popover', label: 'Popover' }, { value: 'add', label: 'Add Download window' }, { value: 'trust', label: 'Trust window' }, { value: 'prefs', label: 'Preferences window' }]}
          onChange={(v) => setTweak('surface', v)} />

        <TweakSection label="State" />
        <TweakRadio label="Activity" value={t.scenario} options={[{ value: 'busy', label: 'Busy' }, { value: 'light', label: 'Light' }, { value: 'empty', label: 'First run' }]}
          onChange={(v) => setTweak('scenario', v)} />
        <TweakSelect label="Daemon" value={t.daemon}
          options={[{ value: 'connected', label: 'Connected' }, { value: 'reconnecting', label: 'Reconnecting' }, { value: 'failed', label: 'Unreachable' }]}
          onChange={(v) => setTweak('daemon', v)} />
        <TweakSelect label="Menu-bar icon" value={t.iconState}
          options={[{ value: 'auto', label: 'Auto (derive)' }, { value: 'idle', label: 'Idle' }, { value: 'active', label: 'Active' }, { value: 'done', label: 'Done' }, { value: 'paused', label: 'Paused' }, { value: 'error', label: 'Error' }]}
          onChange={(v) => setTweak('iconState', v)} />

        <TweakSection label="Appearance" />
        <TweakRadio label="Desktop" value={t.appearance} options={[{ value: 'dark', label: 'Dark' }, { value: 'light', label: 'Light' }]}
          onChange={(v) => setTweak('appearance', v)} />
        <TweakRadio label="Density" value={t.density} options={[{ value: 'comfortable', label: 'Comfortable' }, { value: 'compact', label: 'Compact' }]}
          onChange={(v) => setTweak('density', v)} />
        <TweakToggle label="Reduce motion" value={t.reduceMotion} onChange={(v) => setTweak('reduceMotion', v)} />
      </TweaksPanel>
    </>
  );
}

if (!document.getElementById('goh-reduce-style')) {
  const s = document.createElement('style');
  s.id = 'goh-reduce-style';
  s.textContent = '.goh-reduce *{animation:none !important}';
  document.head.appendChild(s);
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
