/* anim.jsx — the menu-bar icon lifecycle: idle → active → done → idle */
/* eslint-disable */

const CYCLE = 6.2;
function phaseAt(t) {
  if (t < 0.8) return { progress: 0, arrowOp: 0, bloom: 0, label: 'Idle', sub: 'No active downloads — green held back', state: 'idle', pct: null };
  if (t < 1.0) { const k = (t - 0.8) / 0.2; return { progress: 0, arrowOp: 0.5 * k, bloom: 0, label: 'Download starts', sub: 'The arrow lights phosphor', state: 'active', pct: 0 }; }
  if (t < 4.5) { const k = (t - 1.0) / 3.5; return { progress: k, arrowOp: 0.5 + 0.5 * k, bloom: 0, label: 'Downloading', sub: 'Brightness tracks real progress', state: 'active', pct: Math.round(k * 100) }; }
  if (t < 5.1) { const k = (t - 4.5) / 0.6; return { progress: 1, arrowOp: 1, bloom: Math.sin(k * Math.PI), label: 'Complete', sub: 'Holds full green ~600 ms', state: 'done', pct: 100 }; }
  if (t < 5.7) { const k = (t - 5.1) / 0.6; return { progress: 1, arrowOp: 1 - k, bloom: 0, label: 'Settling', sub: 'Arrow recedes to rest', state: 'done', pct: 100 }; }
  return { progress: 0, arrowOp: 0, bloom: 0, label: 'Idle', sub: 'Back to rest', state: 'idle', pct: null };
}

// big animated glyph — g + arrow, arrow brightness/glow driven by progress
function BigGlyph({ h = 150, ph }) {
  const vw = 272, vh = 244, w = h * (vw / vh);
  const glow = 2 + ph.progress * 12;
  return (
    <svg height={h} width={w} viewBox={`20 94 ${vw} ${vh}`} style={{ display: 'block', overflow: 'visible' }}>
      {ph.bloom > 0 && <circle cx="268" cy="178" r={14 + ph.bloom * 34} fill={T.green} opacity={ph.bloom * 0.4} style={{ filter: 'blur(6px)' }} />}
      {ph.arrowOp > 0 && (
        <polygon points={ARROW_PTS} fill={T.green} opacity={ph.arrowOp}
          style={{ filter: `drop-shadow(0 0 ${glow}px ${T.green})`, transition: 'none' }} />
      )}
      <path d={G_D} fill={T.type} fillRule="evenodd" />
    </svg>
  );
}

function MiniGlyph({ ph }) {
  const vw = 272, vh = 244, h = 16, w = h * (vw / vh);
  return (
    <svg height={h} width={w} viewBox={`20 94 ${vw} ${vh}`} style={{ display: 'block', overflow: 'visible' }}>
      {ph.arrowOp > 0 && <polygon points={ARROW_PTS} fill={T.green} opacity={ph.arrowOp} style={{ filter: `drop-shadow(0 0 ${1 + ph.progress * 3}px ${T.green})` }} />}
      <path d={G_D} fill={T.type} fillRule="evenodd" />
    </svg>
  );
}

function PhaseChip({ active, color, children }) {
  return (
    <span style={{ fontFamily: FONT.mono, fontSize: 9.5, fontWeight: 600, letterSpacing: '0.1em', textTransform: 'uppercase',
      color: active ? (color || T.green) : T.faint, opacity: active ? 1 : 0.5, transition: 'opacity .2s, color .2s' }}>{children}</span>
  );
}

function IconLifecycle() {
  const [t, setT] = useState(() => { const v = parseFloat(localStorage.getItem('goh-anim-t') || '0'); return isFinite(v) ? v : 0; });
  const [playing, setPlaying] = useState(() => localStorage.getItem('goh-anim-playing') !== 'false');
  const raf = useRef(0); const last = useRef(0);

  useEffect(() => {
    localStorage.setItem('goh-anim-playing', String(playing));
    if (!playing) return;
    last.current = performance.now();
    const loop = (now) => {
      const dt = (now - last.current) / 1000; last.current = now;
      setT((p) => { const n = (p + dt) % CYCLE; localStorage.setItem('goh-anim-t', n.toFixed(2)); return n; });
      raf.current = requestAnimationFrame(loop);
    };
    raf.current = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf.current);
  }, [playing]);

  const ph = phaseAt(t);
  const isActive = t >= 0.8 && t < 4.5;
  const isDone = t >= 4.5 && t < 5.7;

  return (
    <div style={{ position: 'fixed', inset: 0, background: `radial-gradient(120% 90% at 50% -10%, #18202b 0%, rgba(24,32,43,0) 55%), linear-gradient(170deg, #0e1118, #08090d)`,
      fontFamily: FONT.ui, color: T.type, display: 'flex', flexDirection: 'column' }}>

      {/* menu bar with the live icon */}
      <div style={{ height: 28, display: 'flex', alignItems: 'center', padding: '0 12px', background: 'rgba(14,16,22,0.6)', backdropFilter: 'blur(40px)', WebkitBackdropFilter: 'blur(40px)', borderBottom: `0.5px solid rgba(255,255,255,0.07)` }}>
        <span style={{ fontFamily: FONT.serif, fontStyle: 'italic', fontWeight: 700, fontSize: 13.5, marginRight: 18 }}>goh</span>
        {['File', 'Edit', 'View'].map((m) => <span key={m} style={{ fontSize: 13, opacity: 0.82, marginRight: 16 }}>{m}</span>)}
        <span style={{ flex: 1 }} />
        <span style={{ display: 'flex', alignItems: 'center', gap: 15, whiteSpace: 'nowrap', flexShrink: 0 }}>
          <Icon d={P.search} size={13} sw={1.6} color="rgba(244,237,224,0.8)" />
          <span style={{ display: 'inline-flex', alignItems: 'center', padding: '2px 5px', borderRadius: 5, background: ph.arrowOp > 0.2 ? 'rgba(107,250,155,0.12)' : 'rgba(255,255,255,0.10)', transition: 'background .2s' }}>
            <MiniGlyph ph={ph} />
          </span>
          <span style={{ fontSize: 13, fontFamily: FONT.mono, fontWeight: 500, opacity: 0.9 }}>9:41 AM</span>
        </span>
      </div>

      {/* hero */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 30 }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 22 }}>
          <div style={{ position: 'relative', height: 170, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <BigGlyph h={150} ph={ph} />
          </div>
          <div style={{ textAlign: 'center', minHeight: 56 }}>
            <div style={{ fontFamily: FONT.mono, fontSize: 13, fontWeight: 600, letterSpacing: '0.06em', color: ph.state === 'idle' ? T.dim : T.green, textTransform: 'uppercase' }}>
              {ph.label}{ph.pct != null && ph.state !== 'idle' ? <span style={{ color: T.type, marginLeft: 8 }}>{ph.pct}%</span> : ''}
            </div>
            <div style={{ fontSize: 12.5, color: T.dim, marginTop: 6 }}>{ph.sub}</div>
          </div>
        </div>

        {/* phase rail */}
        <div style={{ width: 460, maxWidth: '80vw' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
            <PhaseChip active={ph.state === 'idle' && t < 0.8}>Idle</PhaseChip>
            <PhaseChip active={isActive}>Active</PhaseChip>
            <PhaseChip active={isDone}>Done</PhaseChip>
            <PhaseChip active={t >= 5.7}>Idle</PhaseChip>
          </div>
          <div style={{ position: 'relative', height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.08)', overflow: 'hidden' }}>
            <div style={{ position: 'absolute', inset: 0, width: `${(t / CYCLE) * 100}%`, background: T.green, borderRadius: 2, boxShadow: `0 0 8px ${T.greenDim}` }} />
          </div>
          <input type="range" min="0" max={CYCLE} step="0.01" value={t}
            onChange={(e) => { const v = parseFloat(e.target.value); setT(v); localStorage.setItem('goh-anim-t', v.toFixed(2)); }}
            style={{ width: '100%', marginTop: 12, accentColor: T.green, cursor: 'pointer' }} />
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 6 }}>
            <button className="goh-btn" onClick={() => setPlaying((p) => !p)}
              style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '7px 14px', borderRadius: 8, border: 'none', background: 'rgba(255,255,255,0.06)', color: T.type, fontSize: 12, fontWeight: 600, cursor: 'pointer' }}>
              {playing ? <GlyphPause size={12} color={T.type} /> : <GlyphPlay size={12} color={T.green} />}
              {playing ? 'Pause' : 'Play'}
            </button>
            <span style={{ fontFamily: FONT.mono, fontSize: 11, color: T.faint }}>{t.toFixed(1)}s / {CYCLE.toFixed(1)}s · loops</span>
          </div>
        </div>
      </div>

      {/* caption */}
      <div style={{ padding: '0 26px 22px', maxWidth: 560 }}>
        <span style={{ fontFamily: FONT.serif, fontStyle: 'italic', fontWeight: 700, fontSize: 15, color: 'rgba(244,237,224,0.8)' }}>goh</span>
        <span style={{ marginLeft: 8, fontFamily: FONT.mono, fontSize: 10, letterSpacing: '0.04em', color: T.faint }}>· menu-bar icon lifecycle</span>
        <div style={{ fontSize: 12, color: T.dim, marginTop: 6, lineHeight: 1.5 }}>
          The single sanctioned animation: the arrow brightens <em>only</em> while a real download progresses, holds full green for ~600 ms at completion, then recedes. At rest the glyph is a plain monochrome <span style={{ fontFamily: FONT.serif, fontStyle: 'italic' }}>g</span> — no idle motion.
        </div>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<IconLifecycle />);
