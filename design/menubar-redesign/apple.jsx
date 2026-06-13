/* apple.jsx — a true-HIG rebuild of the goh popover.
   One type family (SF), monospaced digits (not a mono face), grouped inset modules,
   semantic colors (systemRed for errors), brand reduced to the icon + a green tint,
   static determinate progress bars. No serif, no mono typeface, no editorial chrome. */
/* eslint-disable */
const { useState: useS, useEffect: useE, useRef: useR } = window;

const SF = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", system-ui, sans-serif';
const SFR = '-apple-system, BlinkMacSystemFont, "SF Pro Rounded", "SF Pro Text", system-ui, sans-serif';
const NUM = { fontVariantNumeric: 'tabular-nums', fontFeatureSettings: '"tnum"' };

function appleTokens(dark) {
  return {
    dark,
    label: dark ? 'rgba(255,255,255,0.92)' : 'rgba(0,0,0,0.88)',
    sec: dark ? 'rgba(255,255,255,0.55)' : 'rgba(0,0,0,0.5)',
    ter: dark ? 'rgba(255,255,255,0.28)' : 'rgba(0,0,0,0.28)',
    sep: dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.09)',
    module: dark ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.6)',
    hover: dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)',
    green: dark ? '#34D266' : '#28A85A',         // systemGreen-tuned to the brand hue
    red: dark ? '#FF453A' : '#FF3B30',           // systemRed
    track: dark ? 'rgba(255,255,255,0.18)' : 'rgba(0,0,0,0.12)',
    pop: dark
      ? 'linear-gradient(180deg, rgba(48,52,64,0.5), rgba(26,29,38,0.58))'
      : 'linear-gradient(180deg, rgba(248,248,250,0.74), rgba(242,242,245,0.78))',
    hair: dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.08)',
    topHi: dark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.8)',
    ctrl: dark ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.06)',
    onAccent: '#FFFFFF',
  };
}

// SF-symbol-ish circular control (Safari download stop/resume button)
function CircleCtrl({ kind, color, ring, onClick }) {
  return (
    <button className="goh-btn" onClick={onClick} style={{ width: 22, height: 22, borderRadius: 11, border: 'none', padding: 0, cursor: 'pointer', background: 'transparent', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="22" height="22" viewBox="0 0 22 22">
        <circle cx="11" cy="11" r="10" fill="none" stroke={ring} strokeWidth="1.5" />
        {kind === 'pause' && <g fill={color}><rect x="8" y="7.5" width="2" height="7" rx="1" /><rect x="12" y="7.5" width="2" height="7" rx="1" /></g>}
        {kind === 'play' && <path d="M9 7.5l6 3.5-6 3.5z" fill={color} />}
        {kind === 'stop' && <rect x="7.5" y="7.5" width="7" height="7" rx="1.5" fill={color} />}
        {kind === 'retry' && <g fill="none" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M14.6 8a4.2 4.2 0 10.8 4.6" /><path d="M15 5.2v3h-3" /></g>}
      </svg>
    </button>
  );
}

function HeaderBtn({ d, c, onClick }) {
  const [h, setH] = useS(false);
  return (
    <button className="goh-btn" onClick={onClick} onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ width: 26, height: 26, borderRadius: 13, border: 'none', cursor: 'pointer', background: h ? c.ctrl : 'transparent', color: c.sec, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <Icon d={d} size={16} sw={1.7} />
    </button>
  );
}

function AppleBar({ pct, color, track }) {
  return (
    <div style={{ height: 4, borderRadius: 2, background: track, overflow: 'hidden' }}>
      <div style={{ height: '100%', width: `${pct}%`, borderRadius: 2, background: color }} />
    </div>
  );
}

function ModuleLabel({ children, c, action, onAction }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', padding: '0 6px 6px', margin: '0 10px' }}>
      <span style={{ fontFamily: SF, fontSize: 14, fontWeight: 600, color: c.label, letterSpacing: '-0.01em' }}>{children}</span>
      {action && <span style={{ fontFamily: SF, fontSize: 12.5, color: c.green, cursor: 'pointer' }}>{action}</span>}
    </div>
  );
}

// small plain glyph button revealed on row hover (copy / remove)
function RowGlyphBtn({ d, c, danger, title, onClick }) {
  const [h, setH] = useS(false);
  return (
    <button className="goh-btn" title={title} onClick={(e) => { e.stopPropagation(); onClick && onClick(); }}
      onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ width: 22, height: 22, borderRadius: 11, border: 'none', padding: 0, cursor: 'pointer', flexShrink: 0,
        background: h ? c.ctrl : 'transparent', color: danger ? c.red : (h ? c.label : c.sec), display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <Icon d={d} size={13} sw={1.7} />
    </button>
  );
}

// Apple-style inline notice (offline / on cellular / low disk) shown atop the popover.
const NOTICE = {
  offline: { d: 'M5 12.5a10 10 0 0114 0 M8 15.4a6 6 0 018 0 M11.4 18.4h1.2 M4 4l16 16', title: 'No Internet Connection', sub: 'Transfers will resume when you reconnect.', action: null, danger: false },
  cellular: { d: 'M4 16h1.6v4H4z M9.2 12h1.6v8H9.2z M14.4 8h1.6v12h-1.6z M19.6 4h1.6v16h-1.6z', title: 'Paused on Cellular', sub: 'Data Saver is keeping transfers off cellular.', action: 'Resume', danger: false },
  lowdisk: { d: 'M12 3.2L2.6 19a1 1 0 00.87 1.5h17.06A1 1 0 0021.4 19L12 3.2z M12 10v4 M11.9 17.1h.2', title: 'Startup Disk Almost Full', sub: '1.2 GB available — may not finish.', action: 'Manage…', danger: true },
};
function NoticeBanner({ kind, c }) {
  const n = NOTICE[kind];
  if (!n) return null;
  const accent = n.danger ? c.red : c.label;
  return (
    <div style={{ margin: '0 10px 12px', borderRadius: 12, padding: '10px 12px', display: 'flex', alignItems: 'center', gap: 10,
      background: n.danger ? (c.dark ? 'rgba(255,69,58,0.12)' : 'rgba(255,59,48,0.08)') : c.module,
      boxShadow: n.danger ? `inset 0 0 0 0.5px ${c.dark ? 'rgba(255,69,58,0.28)' : 'rgba(255,59,48,0.22)'}` : 'none' }}>
      <Icon d={n.d} size={17} sw={1.6} color={n.danger ? c.red : c.sec} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12.5, fontWeight: 600, color: c.label }}>{n.title}</div>
        <div style={{ fontSize: 11, color: c.sec, marginTop: 1, lineHeight: 1.3 }}>{n.sub}</div>
      </div>
      {n.action && (
        <button className="goh-btn" style={{ border: 'none', cursor: 'pointer', padding: '4px 11px', borderRadius: 7, flexShrink: 0,
          background: c.dark ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.06)', color: n.danger ? c.red : c.green, fontFamily: SF, fontSize: 12, fontWeight: 600 }}>{n.action}</button>
      )}
    </div>
  );
}

// the macOS overflow menu opened from the header ⋯ button
// Right-click context menu (native-style, positioned at the cursor).
function CtxItem({ it, c, onClose }) {
  const [h, setH] = useS(false);
  return (
    <button className="goh-btn" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)} onClick={onClose}
      style={{ display: 'flex', alignItems: 'center', gap: 9, width: '100%', padding: '6px 11px', border: 'none', cursor: 'pointer', textAlign: 'left',
        background: h ? (it.danger ? c.red : c.green) : 'transparent', color: h ? c.onAccent : (it.danger ? c.red : c.label), fontFamily: SF, fontSize: 12.5, borderRadius: 6 }}>
      {it.icon ? <Icon d={it.icon} size={14} sw={1.7} color={h ? c.onAccent : (it.danger ? c.red : c.sec)} /> : <span style={{ width: 14 }} />}
      {it.label}
    </button>
  );
}
function CtxMenu({ ctx, c, onClose }) {
  if (!ctx) return null;
  const x = Math.max(2, Math.min(ctx.x, 320 - 206));
  return (
    <>
      <div onClick={onClose} onContextMenu={(e) => { e.preventDefault(); onClose(); }} style={{ position: 'fixed', inset: 0, zIndex: 60 }} />
      <div style={{ position: 'absolute', left: x, top: ctx.y, width: 202, zIndex: 61, padding: 5, borderRadius: 10, fontFamily: SF,
        background: c.pop, backdropFilter: 'blur(60px) saturate(180%)', WebkitBackdropFilter: 'blur(60px) saturate(180%)',
        boxShadow: `inset 0 0 0 0.5px ${c.hair}, 0 16px 48px rgba(0,0,0,0.45)` }}>
        {ctx.items.map((it, i) => it === 'sep'
          ? <div key={i} style={{ height: 0.5, background: c.sep, margin: '5px 8px' }} />
          : <CtxItem key={i} it={it} c={c} onClose={onClose} />)}
      </div>
    </>
  );
}
// items for a given job, by state
function ctxItemsFor(j) {
  if (j.state === 'active' || j.state === 'paused') return [
    { label: j.state === 'active' ? 'Pause' : 'Resume', icon: P.pulse }, { label: 'Copy URL', icon: P.link }, { label: 'Copy Destination', icon: P.copy }, { label: 'Reveal in Finder', icon: P.folder }, 'sep', { label: 'Remove', icon: P.x, danger: true }];
  if (j.state === 'queued') return [{ label: 'Start Now', icon: P.download }, { label: 'Copy URL', icon: P.link }, 'sep', { label: 'Remove', icon: P.x, danger: true }];
  if (j.state === 'failed') return [{ label: 'Retry', icon: P.refresh }, { label: 'Copy URL', icon: P.link }, 'sep', { label: 'Remove', icon: P.x, danger: true }];
  return [{ label: 'Open', icon: P.download }, { label: 'Reveal in Finder', icon: P.folder }, { label: 'Copy URL', icon: P.link }, { label: 'Verify & Trust…', icon: P.shield }, 'sep', { label: 'Remove from List', icon: P.x, danger: true }];
}

function HeaderMenu({ c, onClose }) {
  const item = (d, label, opts = {}) => {
    const [h, setH] = useS(false);
    return (
      <button key={label} className="goh-btn" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)} onClick={onClose}
        style={{ display: 'flex', alignItems: 'center', gap: 9, width: '100%', padding: '6px 11px', border: 'none', cursor: 'pointer', textAlign: 'left',
          background: h ? c.green : 'transparent', color: h ? c.onAccent : (opts.danger ? c.label : c.label), fontFamily: SF, fontSize: 12.5, borderRadius: 6 }}>
        {d ? <Icon d={d} size={14} sw={1.7} color={h ? c.onAccent : c.sec} /> : <span style={{ width: 14 }} />}
        {label}
      </button>
    );
  };
  return (
    <>
      <div onClick={onClose} style={{ position: 'fixed', inset: 0, zIndex: 8 }} />
      <div style={{ position: 'absolute', top: 38, right: 10, width: 188, zIndex: 9, padding: 5, borderRadius: 10,
        fontFamily: SF, background: c.pop, backdropFilter: 'blur(60px) saturate(180%)', WebkitBackdropFilter: 'blur(60px) saturate(180%)',
        boxShadow: `inset 0 0 0 0.5px ${c.hair}, 0 14px 44px rgba(0,0,0,0.4)` }}>
        {item(P.stack, 'All Downloads…')}
        {item(P.shield, 'Verify & Trust…')}
        {item(P.terminal, 'Open in Terminal')}
        <div style={{ height: 0.5, background: c.sep, margin: '5px 8px' }} />
        {item(P.gear, 'Settings…')}
        <div style={{ height: 0.5, background: c.sep, margin: '5px 8px' }} />
        {item(null, 'Quit goh')}
      </div>
    </>
  );
}

const DEFAULT_CLIP = 'huggingface.co/meta-llama/Llama-3.1-70B/model-00003.safetensors';

// a single in-transit row with hover-revealed copy/remove + always-on primary control
function AStreamRow({ j, c, top, onToggle, onRemove, onCtx }) {
  const [h, setH] = useS(false);
  const [stem, ext] = splitName(j.name);
  const paused = j.state === 'paused';
  const queued = j.state === 'queued';
  const error = j.state === 'error';
  const barColor = error ? c.red : paused ? c.sec : c.green;
  return (
    <div onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)} onContextMenu={(e) => onCtx && onCtx(e, j)}
      style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '9px 10px 9px 12px', borderTop: top ? `0.5px solid ${c.sep}` : 'none' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontFamily: SF, fontSize: 14, color: c.label, fontWeight: 400, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{stem}{ext}</div>
        <div style={{ marginTop: 6, marginBottom: 5 }}><AppleBar pct={queued ? 0 : j.pct} color={barColor} track={c.track} /></div>
        <div style={{ fontFamily: SF, fontSize: 12, color: error ? c.red : c.sec, ...NUM }}>
          {error ? (j.error || 'Couldn’t connect — check your network')
            : queued ? 'Waiting…'
            : paused ? `Paused — ${j.done} of ${j.total}`
            : `${j.done} of ${j.total} — ${j.speed}`}
        </div>
      </div>
      {h && <RowGlyphBtn d={P.folder} c={c} title="Reveal in Finder" />}
      {h && <RowGlyphBtn d={P.x} c={c} danger title="Remove" onClick={() => onRemove(j.id)} />}
      {error
        ? <CircleCtrl kind="retry" color={c.green} ring={c.sep} onClick={() => onToggle(j.id)} />
        : <CircleCtrl kind={paused || queued ? 'play' : 'pause'} color={c.sec} ring={c.sep} onClick={() => onToggle(j.id)} />}
    </div>
  );
}

function AppleManifest({ mode = 'dark', right = 16, notchRight = 74, jobs: jobsProp = JOBS, daemon = 'connected', clip = DEFAULT_CLIP, notice = null }) {
  const c = appleTokens(mode === 'dark');
  const [jobs, setJobs] = useS(jobsProp);
  useE(() => { setJobs(jobsProp); }, [jobsProp]);
  const [menu, setMenu] = useS(false);
  const [ctx, setCtx] = useS(null);
  const popRef = useR(null);
  const openCtx = (e, j) => {
    e.preventDefault();
    const host = popRef.current;
    if (!host) return;
    const rect = host.getBoundingClientRect();
    const scale = rect.width / host.offsetWidth || 1;
    setCtx({ items: ctxItemsFor(j), x: (e.clientX - rect.left) / scale, y: (e.clientY - rect.top) / scale });
  };
  const toggle = (id) => setJobs((js) => js.map((j) => j.id === id ? { ...j, state: j.state === 'active' ? 'paused' : 'active', speed: j.state === 'active' ? null : '5.1 MB/s' } : j));
  const remove = (id) => setJobs((js) => js.filter((j) => j.id !== id));
  const actives = jobs.filter((j) => j.state === 'active');
  const hero = actives[0];
  const [heroH, setHeroH] = useS(false);
  const others = jobs.filter((j) => ['active', 'paused', 'queued', 'error'].includes(j.state) && (!hero || j.id !== hero.id));
  const recent = jobs.filter((j) => ['completed', 'failed'].includes(j.state)).slice(0, 3);

  const failed = daemon === 'failed';
  const reconnecting = daemon === 'reconnecting';
  const glyphState = failed ? 'error' : reconnecting ? 'paused' : actives.length ? 'active' : 'idle';

  const statusMain = failed ? 'Service unreachable' : reconnecting ? 'Reconnecting…' : actives.length ? `${actives.length} downloading` : 'No active downloads';
  const statusSub = failed ? 'Your ledger still works offline' : reconnecting ? 'Reattaching to gohd' : actives.length ? '6.4 MB/s · 48 tracked' : '48 tracked';

  return (
    <div style={{ position: 'absolute', top: 31, right, zIndex: 4 }}>
      <div style={{ position: 'absolute', top: -6, right: notchRight, width: 14, height: 7, overflow: 'hidden' }}>
        <div style={{ position: 'absolute', top: 2.5, left: 1, width: 11, height: 11, transform: 'rotate(45deg)', background: c.pop, backdropFilter: 'blur(72px) saturate(185%)', WebkitBackdropFilter: 'blur(72px) saturate(185%)', boxShadow: `inset 0 0 0 0.5px ${c.hair}` }} />
      </div>
      <div ref={popRef} style={{ position: 'relative', width: 320, borderRadius: 18, overflow: 'visible', fontFamily: SF, background: c.pop,
        backdropFilter: 'blur(72px) saturate(185%)', WebkitBackdropFilter: 'blur(72px) saturate(185%)',
        boxShadow: `inset 0 0 0 0.5px ${c.hair}, inset 0 1px 0 ${c.topHi}, 0 22px 70px rgba(0,0,0,0.5), 0 6px 18px rgba(0,0,0,0.3)` }}>
        <div style={{ borderRadius: 18, overflow: 'hidden' }}>

        {/* header */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '13px 13px 12px' }}>
          <GohWordmarkTile h={26} light={!c.dark} state={glyphState} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontFamily: SF, fontSize: 13.5, fontWeight: 600, color: failed ? c.red : c.label, letterSpacing: '-0.01em', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', display: 'flex', alignItems: 'center', gap: 5 }}>
              {reconnecting && <span style={{ width: 5, height: 5, borderRadius: 3, background: c.sec, animation: 'gohPulse 1.4s ease-in-out infinite', flexShrink: 0 }} />}{statusMain}
            </div>
            <div style={{ fontFamily: SF, fontSize: 11.5, color: c.sec, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', marginTop: 1, ...NUM }}>{statusSub}</div>
          </div>
          <HeaderBtn d={P.plus} c={c} />
          <HeaderBtn d={P.folder} c={c} />
          <HeaderBtn d={P.dots} c={c} onClick={() => setMenu((v) => !v)} />
        </div>

        {failed ? (
          /* recovery banner — Recent still renders below (reads offline) */
          <div style={{ margin: '0 10px 12px', borderRadius: 12, padding: '13px', background: mode === 'dark' ? 'rgba(255,69,58,0.12)' : 'rgba(255,59,48,0.08)', boxShadow: `inset 0 0 0 0.5px ${mode === 'dark' ? 'rgba(255,69,58,0.3)' : 'rgba(255,59,48,0.25)'}` }}>
            <div style={{ display: 'flex', gap: 9, alignItems: 'flex-start' }}>
              <Icon d="M12 3.2L2.6 19a1 1 0 00.87 1.5h17.06A1 1 0 0021.4 19L12 3.2z M12 10v4 M12 17.2v.2" size={17} sw={1.6} color={c.red} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 12.5, fontWeight: 600, color: c.label }}>Background service unreachable</div>
                <div style={{ fontSize: 11.5, color: c.sec, marginTop: 2, lineHeight: 1.35 }}>goh’s helper isn’t responding. Your ledger still works offline.</div>
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, marginTop: 11 }}>
              <button className="goh-btn" style={{ flex: 1, padding: '7px 0', borderRadius: 8, border: 'none', cursor: 'pointer', background: c.dark ? 'rgba(255,255,255,0.14)' : '#fff', color: c.label, fontFamily: SF, fontSize: 12.5, fontWeight: 600, boxShadow: c.dark ? 'none' : 'inset 0 0 0 0.5px rgba(0,0,0,0.06)' }}>Open Doctor</button>
              <button className="goh-btn" style={{ flex: 1, padding: '7px 0', borderRadius: 8, border: 'none', cursor: 'pointer', background: 'transparent', color: c.sec, fontFamily: SF, fontSize: 12.5, fontWeight: 500, boxShadow: `inset 0 0 0 0.5px ${c.sep}` }}>Copy Command</button>
            </div>
          </div>
        ) : (
          <>
            {notice && <NoticeBanner kind={notice} c={c} />}
            {/* clipboard CTA — appears only when a URL is detected */}
            {clip && (
              <div style={{ margin: '0 10px 12px' }}>
                <button className="goh-btn" style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 10, padding: '9px 10px 9px 12px', borderRadius: 12, border: 'none', cursor: 'pointer',
                  background: c.module, color: c.label, textAlign: 'left' }}>
                  <Icon d={P.clipboard} size={16} sw={1.6} color={c.green} />
                  <span style={{ flex: 1, minWidth: 0 }}>
                    <span style={{ display: 'block', fontSize: 13.5, fontWeight: 500, color: c.label }}>Download from Clipboard</span>
                    <span style={{ display: 'block', fontSize: 11, color: c.sec, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', ...NUM }}>{clip}</span>
                  </span>
                  <span style={{ width: 26, height: 26, borderRadius: 13, background: c.green, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                    <Icon d="M12 4v10 M8 11l4 3 4-3" size={15} sw={2} color={c.onAccent} />
                  </span>
                </button>
              </div>
            )}

            {/* hero (active) */}
            {hero && (
              <div onMouseEnter={() => setHeroH(true)} onMouseLeave={() => setHeroH(false)} onContextMenu={(e) => openCtx(e, hero)} style={{ margin: '0 10px 12px', borderRadius: 12, background: c.module, padding: '12px 13px' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontFamily: SF, fontSize: 15, fontWeight: 500, color: c.label, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{hero.name}</div>
                  </div>
                  {heroH && <RowGlyphBtn d={P.link} c={c} title="Copy URL" />}
                  {heroH && <RowGlyphBtn d={P.x} c={c} danger title="Remove" onClick={() => remove(hero.id)} />}
                  <span style={{ fontFamily: SF, fontSize: 14.5, color: c.sec, fontWeight: 500, ...NUM }}>{hero.pct}%</span>
                </div>
                <div style={{ margin: '9px 0 8px' }}><AppleBar pct={hero.pct} color={c.green} track={c.track} /></div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontFamily: SF, fontSize: 12.5, color: c.sec, flex: 1, ...NUM }}>{hero.done} of {hero.total} — {hero.speed} — {hero.eta} left</span>
                  <CircleCtrl kind="pause" color={c.sec} ring={c.sep} onClick={() => toggle(hero.id)} />
                </div>
              </div>
            )}

            {/* other transfers */}
            {others.length > 0 && (
              <div style={{ marginBottom: 12 }}>
                <ModuleLabel c={c}>Downloading</ModuleLabel>
                <div style={{ margin: '0 10px', borderRadius: 12, background: c.module, overflow: 'hidden' }}>
                  {others.map((j, i) => <AStreamRow key={j.id} j={j} c={c} top={i > 0} onToggle={toggle} onRemove={remove} onCtx={openCtx} />)}
                </div>
              </div>
            )}

            {/* empty / first-run */}
            {!hero && others.length === 0 && (
              <div style={{ margin: '0 10px 12px', borderRadius: 12, background: c.module, padding: '18px 14px', textAlign: 'center' }}>
                <div style={{ fontSize: 12.5, color: c.sec }}>No active downloads</div>
                <div style={{ fontSize: 11.5, color: c.ter, marginTop: 3 }}>Copy a link or drag it onto the menu-bar icon.</div>
              </div>
            )}
          </>
        )}

        {/* recent */}
        {recent.length > 0 && (
          <div style={{ marginBottom: 12 }}>
            <ModuleLabel c={c} action="Show All">Recent</ModuleLabel>
            <div style={{ margin: '0 10px', borderRadius: 12, background: c.module, overflow: 'hidden' }}>
              {recent.map((j, i) => {
                const [stem, ext] = splitName(j.name);
                const isFailed = j.state === 'failed';
                return (
                  <div key={j.id} onContextMenu={(e) => openCtx(e, j)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', borderTop: i ? `0.5px solid ${c.sep}` : 'none' }}>
                    <span style={{ fontFamily: SF, fontSize: 14, color: c.label, flex: 1, minWidth: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{stem}{ext}</span>
                    {isFailed
                      ? <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontFamily: SF, fontSize: 12.5, color: c.red }}><Icon d="M12 2a10 10 0 100 20 10 10 0 000-20z M12 7v6 M12 16.5v.5" size={14} sw={1.6} color={c.red} />Failed</span>
                      : <><span style={{ fontFamily: SF, fontSize: 12.5, color: c.sec, ...NUM }}>{j.verified}</span><Icon d="M12 2a10 10 0 100 20 10 10 0 000-20z M8.5 12l2.5 2.5 4.5-5" size={16} sw={1.6} color={c.green} /></>}
                  </div>
                );
              })}
            </div>
          </div>
        )}

        </div>
        {menu && <HeaderMenu c={c} onClose={() => setMenu(false)} />}
        <CtxMenu ctx={ctx} c={c} onClose={() => setCtx(null)} />
      </div>
    </div>
  );
}

function AppleNotification({ mode = 'dark', name = 'sd-xl-base-1.0.safetensors', meta = 'Verified · 6.94 GB' }) {
  const c = appleTokens(mode === 'dark');
  return (
    <div style={{ width: 344, borderRadius: 18, padding: '13px 15px', display: 'flex', gap: 12, alignItems: 'center', fontFamily: SF,
      background: c.pop, backdropFilter: 'blur(72px) saturate(185%)', WebkitBackdropFilter: 'blur(72px) saturate(185%)',
      boxShadow: `inset 0 0 0 0.5px ${c.hair}, inset 0 1px 0 ${c.topHi}, 0 16px 50px rgba(0,0,0,0.45)` }}>
      <span style={{ width: 38, height: 38, borderRadius: 9, background: c.module, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
        <GlyphG size={22} state="done" type={c.label} accent={c.green} dimArrow={c.sec} />
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: c.label }}>Download Complete</span>
          <span style={{ flex: 1 }} />
          <span style={{ fontSize: 11, color: c.ter, ...NUM }}>now</span>
        </div>
        <div style={{ fontSize: 12.5, color: c.sec, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{name}</div>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, marginTop: 6 }}>
          <Icon d="M12 2a10 10 0 100 20 10 10 0 000-20z M8.5 12l2.5 2.5 4.5-5" size={14} sw={1.6} color={c.green} />
          <span style={{ fontSize: 11.5, color: c.sec, ...NUM }}>{meta}</span>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { AppleManifest, AppleNotification, appleTokens, SF, SFR, NUM, CircleCtrl, AppleBar, HeaderBtn, ModuleLabel });
