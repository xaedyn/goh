/* appleProto.jsx — PRIMARY prototype, Apple-HIG language. All surfaces, both appearances. */
/* eslint-disable */

const A_DEFAULTS = /*EDITMODE-BEGIN*/{
  "surface": "popover",
  "live": true,
  "condition": "normal",
  "scenario": "busy",
  "daemon": "connected",
  "iconState": "auto",
  "dragOver": false,
  "appearance": "dark"
}/*EDITMODE-END*/;

const A_SCN = {
  busy: JOBS,
  light: [
    { id: 1, name: 'mistral-7b-v0.3.safetensors', state: 'active', pct: 81, speed: '7.2 MB/s', done: '11.8', total: '14.5 GB', eta: '37s', conns: 8, host: 'huggingface.co' },
    { id: 5, name: 'sd-xl-base-1.0.safetensors', state: 'completed', pct: 100, done: '6.94', total: '6.94 GB', host: 'huggingface.co', verified: 'Jun 5' },
    { id: 6, name: 'config.json', state: 'completed', pct: 100, done: '4.2', total: '4.2 KB', host: 'huggingface.co', verified: 'Jun 5' },
  ],
  empty: [],
};

function aDeriveIcon(scenario, daemon) {
  if (daemon === 'failed') return 'error';
  if (daemon === 'reconnecting') return 'paused';
  const jobs = A_SCN[scenario] || [];
  if (jobs.some((j) => j.state === 'active')) return 'active';
  if (jobs.some((j) => j.state === 'paused')) return 'paused';
  return 'idle';
}

// Vibrant multi-color wallpapers so the glass translucency reads clearly through every surface.
const A_WALL = {
  dark: `radial-gradient(42% 55% at 16% 20%, rgba(56,128,200,0.6) 0%, rgba(56,128,200,0) 62%),
         radial-gradient(46% 52% at 84% 14%, rgba(158,72,196,0.55) 0%, rgba(158,72,196,0) 62%),
         radial-gradient(52% 60% at 76% 86%, rgba(226,128,72,0.46) 0%, rgba(226,128,72,0) 60%),
         radial-gradient(48% 56% at 22% 90%, rgba(36,170,150,0.5) 0%, rgba(36,170,150,0) 60%),
         linear-gradient(150deg, #14162400 0%, #0c0e18 55%, #08090f 100%),
         linear-gradient(150deg, #161827 0%, #0d0f1a 60%, #08090f 100%)`,
  light: `radial-gradient(42% 55% at 15% 18%, rgba(116,176,252,0.72) 0%, rgba(116,176,252,0) 60%),
          radial-gradient(46% 50% at 85% 14%, rgba(248,158,212,0.64) 0%, rgba(248,158,212,0) 62%),
          radial-gradient(52% 60% at 78% 88%, rgba(255,202,138,0.66) 0%, rgba(255,202,138,0) 60%),
          radial-gradient(50% 56% at 22% 90%, rgba(146,234,200,0.62) 0%, rgba(146,234,200,0) 60%),
          linear-gradient(150deg, #e9f0fb 0%, #eef0f8 55%, #f3edf7 100%)`,
};

// ── Live demo engine ──────────────────────────────────────────────────────
// A real-time simulation: active downloads progress, complete and slide into
// Recent, new ones arrive, and the menu-bar icon tracks the activity.
const INCOMING = [
  { name: 'llama-3.1-70b-instruct.safetensors', total: '68.4 GB', sizeNum: 68.4, speed: '5.1 MB/s', rate: 7.5 },
  { name: 'imagenet-val.tar.zst', total: '6.40 GB', sizeNum: 6.40, speed: '1.3 MB/s', rate: 11 },
  { name: 'mistral-7b-v0.3.safetensors', total: '14.5 GB', sizeNum: 14.5, speed: '7.2 MB/s', rate: 9 },
  { name: 'dataset-shard-00007.parquet', total: '512 MB', sizeNum: 512, speed: '3.4 MB/s', rate: 13 },
  { name: 'tokenizer.model', total: '2.1 MB', sizeNum: 2.1, speed: '880 KB/s', rate: 17 },
];
const L_RECENT0 = [
  { id: 90, name: 'sd-xl-base-1.0.safetensors', state: 'completed', verified: 'Jun 5' },
  { id: 91, name: 'config.json', state: 'completed', verified: 'Jun 5' },
  { id: 92, name: 'vocab.bpe', state: 'failed' },
];
function fmtDone(tpl, pct) { const v = pct / 100 * tpl.sizeNum; return tpl.sizeNum >= 100 ? Math.round(v).toString() : v.toFixed(1); }
function fmtEta(tpl, pct) { const rem = Math.max(0, Math.round((100 - pct) / tpl.rate)); return rem >= 60 ? `${Math.floor(rem / 60)}m ${String(rem % 60).padStart(2, '0')}s` : `${rem}s`; }
function mkJob(tpl, id, pct = 0, state = 'active') {
  return { id, name: tpl.name, total: tpl.total, sizeNum: tpl.sizeNum, speed: tpl.speed, rate: tpl.rate, state, pctF: pct, pct: Math.round(pct), done: fmtDone(tpl, pct), eta: fmtEta(tpl, pct) };
}
function liveSeed() {
  return {
    jobs: [mkJob(INCOMING[0], 1, 14, 'active'), mkJob(INCOMING[1], 2, 4, 'active'), mkJob(INCOMING[2], 3, 0, 'queued'), ...L_RECENT0],
    incomingIdx: 3, nextId: 10, doneAt: 0, restAt: null,
  };
}
function liveAdvance(s, dt) {
  let doneAt = s.doneAt, incomingIdx = s.incomingIdx, nextId = s.nextId;
  let jobs = s.jobs.map((j) => {
    if (j.state !== 'active') return j;
    const pctF = j.pctF + j.rate * dt;
    if (pctF >= 100) { doneAt = performance.now(); return { ...j, pctF: 100, pct: 100, state: 'completed', verified: 'now', done: fmtDone(j, 100), eta: null }; }
    return { ...j, pctF, pct: Math.round(pctF), done: fmtDone(j, pctF), eta: fmtEta(j, pctF) };
  });
  const active = jobs.filter((j) => j.state === 'active').length;
  if (active < 2) {
    const qi = jobs.findIndex((j) => j.state === 'queued');
    if (qi >= 0) jobs = jobs.map((j, i) => i === qi ? { ...j, state: 'active' } : j);
    else if (incomingIdx < INCOMING.length) { jobs = [...jobs, mkJob(INCOMING[incomingIdx], nextId, 0, 'active')]; incomingIdx++; nextId++; }
  }
  const anyLive = jobs.some((j) => j.state === 'active' || j.state === 'queued');
  let restAt = anyLive ? null : s.restAt;
  if (!anyLive && incomingIdx >= INCOMING.length) {
    if (!s.restAt) restAt = performance.now();
    else if (performance.now() - s.restAt > 2000) return liveSeed();
  }
  return { jobs, incomingIdx, nextId, doneAt, restAt };
}
function useLiveJobs(enabled) {
  const [s, setS] = useState(liveSeed);
  const raf = useRef(0), last = useRef(0);
  useEffect(() => {
    if (!enabled) return;
    last.current = performance.now();
    const loop = (tn) => { const dt = Math.min(0.05, (tn - last.current) / 1000); last.current = tn; setS((p) => liveAdvance(p, dt)); raf.current = requestAnimationFrame(loop); };
    raf.current = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf.current);
  }, [enabled]);
  const anyActive = s.jobs.some((j) => j.state === 'active');
  const icon = anyActive ? 'active' : (performance.now() - s.doneAt < 800 ? 'done' : 'idle');
  return { jobs: s.jobs, icon };
}

// ── Edge conditions (offline / cellular / low disk / transfer error) ─────────
const EDGE = {
  offline: { notice: 'offline', icon: 'paused', jobs: [
    { id: 1, name: 'llama-3.1-70b-instruct.safetensors', state: 'paused', pct: 62, done: '42.6', total: '68.4 GB' },
    { id: 2, name: 'imagenet-val.tar.zst', state: 'paused', pct: 28, done: '1.79', total: '6.40 GB' },
    ...L_RECENT0,
  ] },
  cellular: { notice: 'cellular', icon: 'paused', jobs: [
    { id: 1, name: 'llama-3.1-70b-instruct.safetensors', state: 'paused', pct: 62, done: '42.6', total: '68.4 GB' },
    { id: 3, name: 'tokenizer.model', state: 'queued', pct: 0, total: '2.1 MB' },
    ...L_RECENT0,
  ] },
  lowdisk: { notice: 'lowdisk', icon: 'active', jobs: [
    { id: 1, name: 'llama-3.1-70b-instruct.safetensors', state: 'active', pct: 88, speed: '5.1 MB/s', done: '60.2', total: '68.4 GB', eta: '24s' },
    { id: 2, name: 'imagenet-val.tar.zst', state: 'active', pct: 41, speed: '1.3 MB/s', done: '2.6', total: '6.40 GB', eta: '3m 12s' },
    ...L_RECENT0,
  ] },
  error: { notice: null, icon: 'error', jobs: [
    { id: 1, name: 'llama-3.1-70b-instruct.safetensors', state: 'active', pct: 62, speed: '5.1 MB/s', done: '42.6', total: '68.4 GB', eta: '1m 12s' },
    { id: 7, name: 'vocab.bpe', state: 'error', pct: 73, done: '0.7', total: '1.0 MB', error: 'Couldn’t connect — server returned 503' },
    { id: 3, name: 'tokenizer.model', state: 'queued', pct: 0, total: '2.1 MB' },
    ...L_RECENT0,
  ] },
};

function AppleProtoScene({ t }) {
  const light = t.appearance === 'light';
  const mode = light ? 'light' : 'dark';
  const cond = t.condition && t.condition !== 'normal' ? t.condition : null;
  const edge = cond ? EDGE[cond] : null;
  const liveOn = !edge && t.live && t.surface === 'popover' && t.daemon === 'connected';
  const liveData = useLiveJobs(liveOn);
  const popJobs = edge ? edge.jobs : (t.live ? liveData.jobs : A_SCN[t.scenario]);
  const popNotice = edge ? edge.notice : null;
  const iconState = t.iconState !== 'auto'
    ? t.iconState
    : (edge ? edge.icon : (liveOn ? liveData.icon : aDeriveIcon(t.scenario, t.daemon)));
  const c = appleTokens(!light);
  const barText = light ? 'rgba(0,0,0,0.85)' : 'rgba(255,255,255,0.92)';
  const barBg = light ? 'rgba(255,255,255,0.5)' : 'rgba(20,22,28,0.5)';
  const barLine = light ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.08)';
  const open = t.surface === 'popover';
  const openHi = light ? 'rgba(0,0,0,0.10)' : 'rgba(255,255,255,0.22)';
  const idleChip = 'transparent';
  const iconType = barText;

  const menuFont = SF;

  return (
    <div style={{ width: 1280, height: 900, position: 'relative', overflow: 'hidden', background: A_WALL[mode], fontFamily: SF }}>
      {/* menu bar — SF, neutral, app name (not a serif lockup) */}
      <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 26, display: 'flex', alignItems: 'center', padding: '0 10px 0 13px',
        background: barBg, backdropFilter: 'blur(40px) saturate(150%)', WebkitBackdropFilter: 'blur(40px) saturate(150%)', borderBottom: `0.5px solid ${barLine}`, zIndex: 5, color: barText }}>
        <span style={{ display: 'inline-flex', alignItems: 'center', marginRight: 16 }}><GlyphG size={14} state="idle" type={barText} /></span>
        <span style={{ fontFamily: menuFont, fontSize: 13.5, fontWeight: 700, marginRight: 18, letterSpacing: '-0.01em' }}>goh</span>
        {['File', 'Edit', 'View', 'Window', 'Help'].map((m) => <span key={m} style={{ fontFamily: menuFont, fontSize: 13, opacity: 0.85, marginRight: 16 }}>{m}</span>)}
        <span style={{ flex: 1 }} />
        <span style={{ display: 'flex', alignItems: 'center', gap: 16, whiteSpace: 'nowrap' }}>
          <Icon d="M9 18V5l8-2v13 M9 9l8-2" size={13} sw={1.5} color={iconType} style={{ opacity: 0.85 }} />
          <Icon d={P.search} size={13} sw={1.6} color={iconType} style={{ opacity: 0.85 }} />
          <span style={{ position: 'relative', display: 'inline-flex' }}>
            <span id="goh-status-item" style={{ display: 'inline-flex', borderRadius: 8, boxShadow: t.dragOver ? `0 0 0 1.5px ${c.green}` : 'none', transition: 'box-shadow .12s' }}>
              <GohWordmarkTile h={22} light={light} state={t.dragOver ? 'active' : iconState} active={open || t.dragOver} />
            </span>
            {t.dragOver && (
              <span style={{ position: 'absolute', top: 30, left: '50%', transform: 'translateX(-50%)', display: 'inline-flex', alignItems: 'center', gap: 6, padding: '5px 10px', borderRadius: 8, background: c.green, color: c.onAccent, fontSize: 11.5, fontWeight: 600, whiteSpace: 'nowrap', boxShadow: '0 6px 16px rgba(0,0,0,0.3)', zIndex: 20 }}>
                <Icon d={P.link} size={11} sw={1.9} color={c.onAccent} /> Drop to download with goh
              </span>
            )}
          </span>
          <span style={{ fontFamily: menuFont, fontSize: 13, fontWeight: 500, ...NUM, opacity: 0.92 }}>Sun Jun 8&nbsp;&nbsp;9:41 AM</span>
        </span>
      </div>

      {/* surface */}
      {t.surface === 'popover' && <AppleManifest mode={mode} jobs={popJobs} daemon={t.daemon} clip={DEFAULT_CLIP} notice={popNotice} />}
      {t.surface === 'add' && <div style={{ position: 'absolute', top: 96, left: 70 }}><AppleAddWindow mode={mode} /></div>}
      {t.surface === 'trust' && <div style={{ position: 'absolute', top: 84, left: 70 }}><AppleTrustWindow mode={mode} /></div>}
      {t.surface === 'downloads' && <div style={{ position: 'absolute', top: 84, left: 70 }}><AppleDownloadsWindow mode={mode} /></div>}
      {t.surface === 'prefs' && <div style={{ position: 'absolute', top: 90, left: 70 }}><ApplePrefsWindow mode={mode} /></div>}
      {t.surface === 'notification' && (
        <div style={{ position: 'absolute', top: 38, right: 14 }}>
          {/* Notification Center grouping — peeking cards behind */}
          <div style={{ position: 'absolute', top: 14, left: 16, right: 16, height: 44, borderRadius: 18, background: mode === 'dark' ? 'rgba(30,33,42,0.5)' : 'rgba(250,250,252,0.5)', backdropFilter: 'blur(40px)', WebkitBackdropFilter: 'blur(40px)', boxShadow: `inset 0 0 0 0.5px ${appleTokens(mode === 'dark').hair}` }} />
          <div style={{ position: 'absolute', top: 7, left: 8, right: 8, height: 44, borderRadius: 18, background: mode === 'dark' ? 'rgba(34,37,47,0.72)' : 'rgba(252,252,254,0.72)', backdropFilter: 'blur(50px)', WebkitBackdropFilter: 'blur(50px)', boxShadow: `inset 0 0 0 0.5px ${appleTokens(mode === 'dark').hair}` }} />
          <div style={{ position: 'relative' }}><AppleNotification mode={mode} /></div>
        </div>
      )}

      {/* caption */}
      <div style={{ position: 'absolute', left: 24, bottom: 22, maxWidth: 320, fontSize: 12, lineHeight: 1.5, color: light ? 'rgba(0,0,0,0.5)' : 'rgba(255,255,255,0.45)', fontFamily: SF }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: light ? 'rgba(0,0,0,0.8)' : 'rgba(255,255,255,0.85)' }}>goh</span>
        <span style={{ marginLeft: 8, fontSize: 11, opacity: 0.85 }}>· Apple-native · live prototype</span>
        <div style={{ marginTop: 5 }}>{t.live ? <>Downloads are <b style={{ color: light ? '#000' : '#fff', fontWeight: 600 }}>running live</b>. Open Tweaks to drive surface, state &amp; appearance.</> : <>Open <b style={{ color: light ? '#000' : '#fff', fontWeight: 600 }}>Tweaks</b> to drive surface, state &amp; appearance.</>}</div>
      </div>
    </div>
  );
}

function AppleStage({ children }) {
  const [vp, setVp] = useState({ w: window.innerWidth, h: window.innerHeight });
  useEffect(() => {
    const r = () => setVp({ w: window.innerWidth, h: window.innerHeight });
    window.addEventListener('resize', r);
    return () => window.removeEventListener('resize', r);
  }, []);
  const scale = Math.min(vp.w / 1280, vp.h / 900);
  return (
    <div style={{ position: 'fixed', inset: 0, background: '#08090d', overflow: 'hidden', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ width: 1280, height: 900, transform: `scale(${scale})`, transformOrigin: 'center center', flexShrink: 0 }}>{children}</div>
    </div>
  );
}

function AppleApp() {
  const [t, setTweak] = useTweaks(A_DEFAULTS);
  return (
    <>
      <AppleStage><AppleProtoScene t={t} /></AppleStage>
      <TweaksPanel title="Tweaks">
        <TweakSection label="Surface" />
        <TweakSelect label="Showing" value={t.surface}
          options={[{ value: 'popover', label: 'Popover' }, { value: 'add', label: 'Add Download' }, { value: 'downloads', label: 'Downloads' }, { value: 'trust', label: 'Trust' }, { value: 'prefs', label: 'Settings' }, { value: 'notification', label: 'Notification' }]}
          onChange={(v) => setTweak('surface', v)} />

        <TweakSection label="State" />
        <TweakToggle label="Live demo" value={t.live} onChange={(v) => setTweak('live', v)} />
        <TweakSelect label="Condition" value={t.condition}
          options={[{ value: 'normal', label: 'Normal' }, { value: 'offline', label: 'Offline' }, { value: 'cellular', label: 'On cellular' }, { value: 'lowdisk', label: 'Low disk space' }, { value: 'error', label: 'Transfer error' }]}
          onChange={(v) => setTweak('condition', v)} />
        <TweakRadio label="Activity" value={t.scenario} options={[{ value: 'busy', label: 'Busy' }, { value: 'light', label: 'Light' }, { value: 'empty', label: 'First run' }]}
          onChange={(v) => setTweak('scenario', v)} />
        <TweakSelect label="Daemon" value={t.daemon}
          options={[{ value: 'connected', label: 'Connected' }, { value: 'reconnecting', label: 'Reconnecting' }, { value: 'failed', label: 'Unreachable' }]}
          onChange={(v) => setTweak('daemon', v)} />
        <TweakSelect label="Menu-bar icon" value={t.iconState}
          options={[{ value: 'auto', label: 'Auto (derive)' }, { value: 'idle', label: 'Idle' }, { value: 'active', label: 'Active' }, { value: 'done', label: 'Done' }, { value: 'paused', label: 'Paused' }, { value: 'error', label: 'Error' }]}
          onChange={(v) => setTweak('iconState', v)} />
        <TweakToggle label="Drag link over icon" value={t.dragOver} onChange={(v) => setTweak('dragOver', v)} />

        <TweakSection label="Appearance" />
        <TweakRadio label="Desktop" value={t.appearance} options={[{ value: 'dark', label: 'Dark' }, { value: 'light', label: 'Light' }]}
          onChange={(v) => setTweak('appearance', v)} />
      </TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<AppleApp />);
