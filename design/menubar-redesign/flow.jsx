/* flow.jsx — end-to-end Add flow: clipboard → Add sheet → hero → complete → notification → Recent.
   A scrubbable, looping guided demo built from the real Apple surfaces. */
/* eslint-disable */
const { useState: useFS, useEffect: useFE, useRef: useFR } = window;

const FLOW_URL = 'huggingface.co/meta-llama/Llama-3.1-70B/model-00003.safetensors';
const ND_NAME = 'model-00003.safetensors';
const ND_TOTAL = 4.20;
const RB = [
  { id: 91, name: 'sd-xl-base-1.0.safetensors', state: 'completed', verified: 'Jun 5' },
  { id: 92, name: 'config.json', state: 'completed', verified: 'Jun 5' },
];
function nd(pct, state) {
  const done = (pct / 100 * ND_TOTAL).toFixed(1);
  const rem = Math.max(0, Math.round((100 - pct) / 14));
  return { id: 50, name: ND_NAME, state, pct: Math.round(pct), speed: '6.1 MB/s', done, total: ND_TOTAL.toFixed(2) + ' GB', eta: rem >= 60 ? `${Math.floor(rem / 60)}m ${rem % 60}s` : `${rem}s` };
}

const DUR = 14;
const ease = (x) => (x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2);
const seg = (t, a, b) => Math.max(0, Math.min(1, (t - a) / (b - a)));

// Director: maps timeline t → the full scene state.
function director(t) {
  let add = 0, notif = 0, jobs, icon = 'idle', caption, step;
  if (t < 2.2) { jobs = [...RB]; caption = 'A download link is on your clipboard.'; step = 0; }
  else if (t < 3.0) { add = ease(seg(t, 2.2, 3.0)); jobs = [...RB]; caption = 'Opening Add Download…'; step = 1; }
  else if (t < 5.0) { add = 1; jobs = [...RB]; caption = 'Set the destination and connections, then Add.'; step = 1; }
  else if (t < 5.7) { add = 1 - ease(seg(t, 5.0, 5.7)); jobs = [nd(0, 'active'), ...RB]; icon = 'active'; caption = 'Added — it becomes the active download.'; step = 2; }
  else if (t < 10.6) { const p = ease(seg(t, 5.7, 10.6)) * 100; jobs = [nd(p, 'active'), ...RB]; icon = 'active'; caption = 'Downloading — hashed in-flight as it arrives.'; step = 2; }
  else if (t < 11.4) { notif = ease(seg(t, 10.6, 11.4)); jobs = [nd(100, 'completed'), ...RB].map((j) => j.id === 50 ? { ...j, verified: 'now' } : j); icon = 'done'; caption = 'Complete.'; step = 3; }
  else if (t < 13.3) { notif = 1; jobs = [{ ...nd(100, 'completed'), verified: 'now' }, ...RB]; icon = 'done'; caption = 'Recorded to your ledger — now in Recent, verified.'; step = 3; }
  else { notif = 1 - ease(seg(t, 13.3, 14)); jobs = [{ ...nd(100, 'completed'), verified: 'now' }, ...RB]; icon = t > 13.7 ? 'idle' : 'done'; caption = 'Done.'; step = 3; }
  return { add, notif, jobs, icon, caption, step };
}

const STEPS = ['Clipboard', 'Add Download', 'Downloading', 'Recorded'];

function FlowScene({ d }) {
  const c = appleTokens(true);
  return (
    <div style={{ width: 1280, height: 900, position: 'relative', overflow: 'hidden', fontFamily: SF,
      background: 'radial-gradient(130% 80% at 82% -8%, #243748 0%, rgba(36,55,72,0) 52%), radial-gradient(95% 70% at 0% 108%, #2c2542 0%, rgba(44,37,66,0) 50%), linear-gradient(165deg, #12151c 0%, #0b0d12 58%, #08090d 100%)' }}>
      {/* menu bar */}
      <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 26, display: 'flex', alignItems: 'center', padding: '0 10px 0 13px',
        background: 'rgba(20,22,28,0.5)', backdropFilter: 'blur(40px) saturate(150%)', WebkitBackdropFilter: 'blur(40px) saturate(150%)', borderBottom: '0.5px solid rgba(255,255,255,0.08)', zIndex: 5, color: 'rgba(255,255,255,0.92)' }}>
        <span style={{ display: 'inline-flex', alignItems: 'center', marginRight: 16 }}><GlyphG size={14} state="idle" type="rgba(255,255,255,0.92)" /></span>
        <span style={{ fontSize: 13.5, fontWeight: 700, marginRight: 18, letterSpacing: '-0.01em' }}>goh</span>
        {['File', 'Edit', 'View', 'Window', 'Help'].map((m) => <span key={m} style={{ fontSize: 13, opacity: 0.85, marginRight: 16 }}>{m}</span>)}
        <span style={{ flex: 1 }} />
        <span style={{ display: 'flex', alignItems: 'center', gap: 16, whiteSpace: 'nowrap' }}>
          <Icon d={P.search} size={13} sw={1.6} color="rgba(255,255,255,0.85)" />
          <span style={{ display: 'inline-flex', alignItems: 'center', padding: '3px 6px', borderRadius: 6, background: (d.icon === 'active' || d.icon === 'done') ? 'rgba(107,250,155,0.18)' : 'transparent', transition: 'background .2s' }}>
            <GlyphG size={16} state={d.icon} type="rgba(255,255,255,0.92)" accent={c.green} bad={c.red} dimArrow={c.sec} />
          </span>
          <span style={{ fontSize: 13, fontWeight: 500, ...NUM, opacity: 0.92 }}>Sun Jun 8&nbsp;&nbsp;9:41 AM</span>
        </span>
      </div>

      {/* popover (always anchored top-right) */}
      <AppleManifest mode="dark" jobs={d.jobs} clip={FLOW_URL} />

      {/* dim layer when the sheet is up */}
      {d.add > 0.01 && <div style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.42)', opacity: d.add, zIndex: 10 }} />}

      {/* Add Download sheet */}
      {d.add > 0.01 && (
        <div style={{ position: 'absolute', top: 150, left: '50%', zIndex: 11,
          transform: `translateX(-50%) scale(${0.92 + 0.08 * d.add}) translateY(${(1 - d.add) * 12}px)`, opacity: d.add }}>
          <AppleAddWindow mode="dark" />
        </div>
      )}

      {/* completion notification */}
      {d.notif > 0.01 && (
        <div style={{ position: 'absolute', top: 38, right: 14, zIndex: 12,
          transform: `translateY(${(1 - d.notif) * -14}px)`, opacity: d.notif }}>
          <AppleNotification mode="dark" name={ND_NAME} meta="Verified · 4.20 GB" />
        </div>
      )}
    </div>
  );
}

function Flow() {
  const [t, setT] = useFS(() => { const v = parseFloat(localStorage.getItem('goh-flow-t') || '0'); return isFinite(v) ? v : 0; });
  const [playing, setPlaying] = useFS(() => localStorage.getItem('goh-flow-playing') !== 'false');
  const [vp, setVp] = useFS({ w: window.innerWidth, h: window.innerHeight });
  const raf = useFR(0), last = useFR(0);

  useFE(() => { const r = () => setVp({ w: window.innerWidth, h: window.innerHeight }); window.addEventListener('resize', r); return () => window.removeEventListener('resize', r); }, []);
  useFE(() => {
    localStorage.setItem('goh-flow-playing', String(playing));
    if (!playing) return;
    last.current = performance.now();
    const loop = (now) => { const dt = (now - last.current) / 1000; last.current = now; setT((p) => { const n = (p + dt) % DUR; localStorage.setItem('goh-flow-t', n.toFixed(2)); return n; }); raf.current = requestAnimationFrame(loop); };
    raf.current = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf.current);
  }, [playing]);

  const d = director(t);
  const scale = Math.min(vp.w / 1280, (vp.h - 92) / 900);

  return (
    <div style={{ position: 'fixed', inset: 0, background: '#08090d', display: 'flex', flexDirection: 'column', fontFamily: SF }}>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden' }}>
        <div style={{ width: 1280, height: 900, transform: `scale(${scale})`, transformOrigin: 'center center', flexShrink: 0, borderRadius: 10, overflow: 'hidden', boxShadow: '0 30px 90px rgba(0,0,0,0.5)' }}>
          <FlowScene d={d} />
        </div>
      </div>

      {/* transport */}
      <div style={{ height: 92, flexShrink: 0, padding: '0 24px', display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 10,
        background: 'rgba(14,16,22,0.9)', borderTop: '0.5px solid rgba(255,255,255,0.08)', color: '#F4EDE0' }}>
        {/* step rail */}
        <div style={{ display: 'flex', gap: 8 }}>
          {STEPS.map((s, i) => (
            <div key={s} style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 5 }}>
              <div style={{ height: 3, borderRadius: 2, background: i <= d.step ? '#34D266' : 'rgba(255,255,255,0.12)', transition: 'background .25s' }} />
              <span style={{ fontFamily: SF, fontSize: 11, fontWeight: i === d.step ? 600 : 400, color: i === d.step ? '#F4EDE0' : 'rgba(244,237,224,0.42)' }}>{i + 1}. {s}</span>
            </div>
          ))}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <button onClick={() => setPlaying((p) => !p)} style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '7px 14px', borderRadius: 8, border: 'none', cursor: 'pointer', background: 'rgba(255,255,255,0.08)', color: '#F4EDE0', fontFamily: SF, fontSize: 12.5, fontWeight: 600 }}>
            {playing ? <GlyphPause size={12} color="#F4EDE0" /> : <GlyphPlay size={12} color="#34D266" />}{playing ? 'Pause' : 'Play'}
          </button>
          <span style={{ fontSize: 12.5, color: 'rgba(244,237,224,0.85)', minWidth: 320, flex: 1 }}>{d.caption}</span>
          <input type="range" min="0" max={DUR} step="0.01" value={t} onChange={(e) => { const v = parseFloat(e.target.value); setT(v); localStorage.setItem('goh-flow-t', v.toFixed(2)); }} style={{ flex: 1.4, accentColor: '#34D266', cursor: 'pointer' }} />
          <span style={{ fontFamily: '"JetBrains Mono", monospace', fontSize: 11, color: 'rgba(244,237,224,0.45)', minWidth: 74, textAlign: 'right' }}>{t.toFixed(1)} / {DUR.toFixed(0)}s</span>
        </div>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<Flow />);
