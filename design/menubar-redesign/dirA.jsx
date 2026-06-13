/* dirA.jsx — Direction A · "Telemetry" — instrument-panel density */
/* eslint-disable */

function Sparkline({ w = 64, h = 18, color = T.green }) {
  // a calm, believable throughput trace
  const pts = [2,5,4,7,6,9,8,11,9,12,10,13,11,10,12,9,11,8];
  const max = 14, step = w / (pts.length - 1);
  const d = pts.map((p, i) => `${i ? 'L' : 'M'}${(i * step).toFixed(1)} ${(h - (p / max) * h).toFixed(1)}`).join(' ');
  return (
    <svg width={w} height={h} style={{ display: 'block', overflow: 'visible' }}>
      <path d={`${d} L${w} ${h} L0 ${h} Z`} fill={T.green} opacity="0.10" />
      <path d={d} fill="none" stroke={color} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx={w} cy={h - (pts[pts.length - 1] / max) * h} r="2" fill={color} />
    </svg>
  );
}

function StatusDot({ state }) {
  if (state === 'active') return <span style={{ width: 7, height: 7, borderRadius: 4, background: T.green, boxShadow: `0 0 7px ${T.green}`, animation: 'gohPulse 1.8s ease-in-out infinite', flexShrink: 0 }} />;
  if (state === 'paused') return <span style={{ width: 7, height: 7, borderRadius: 4, background: T.dim, flexShrink: 0 }} />;
  if (state === 'queued') return <span style={{ width: 7, height: 7, borderRadius: 4, boxShadow: `inset 0 0 0 1.4px ${T.faint}`, flexShrink: 0 }} />;
  if (state === 'failed') return <span style={{ width: 7, height: 7, borderRadius: 4, background: T.oxblood, flexShrink: 0 }} />;
  return <span style={{ width: 7, height: 7, borderRadius: 4, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}><Icon d={P.check} size={9} sw={2.4} color={T.dim} /></span>;
}

function SectionLabel({ children, right }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '0 14px', marginBottom: 7 }}>
      <span style={{ fontFamily: FONT.mono, fontSize: 9.5, fontWeight: 600, letterSpacing: '0.13em', color: T.faint, textTransform: 'uppercase' }}>{children}</span>
      <span style={{ flex: 1, height: 0.5, background: T.hair }} />
      {right && <span style={{ fontFamily: FONT.mono, fontSize: 9.5, fontWeight: 500, letterSpacing: '0.06em', color: T.faint }}>{right}</span>}
    </div>
  );
}

function DenseRow({ job, onToggle }) {
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(job.name);
  const live = job.state === 'active';
  const meta = STATE_META[job.state];
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ padding: '8px 14px 9px', background: h ? 'rgba(255,255,255,0.035)' : 'transparent', position: 'relative' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <StatusDot state={job.state} />
        <span style={{ fontSize: 12.5, fontWeight: 500, color: T.type, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flex: 1 }}>
          {stem}<span style={{ fontFamily: FONT.mono, color: T.dim, fontWeight: 400 }}>{ext}</span>
        </span>
        {/* controls on hover, else the pct */}
        {h ? (
          <span style={{ display: 'flex', gap: 1, marginRight: -4 }}>
            {live && <Ctrl title="Pause" onClick={() => onToggle(job.id)}><GlyphPause /></Ctrl>}
            {job.state === 'paused' && <Ctrl title="Resume" onClick={() => onToggle(job.id)}><GlyphPlay /></Ctrl>}
            <Ctrl title="Copy URL"><Icon d={P.link} size={13} /></Ctrl>
            <Ctrl title="Reveal"><Icon d={P.folder} size={13} /></Ctrl>
            <Ctrl title="Remove" danger><GlyphTrash /></Ctrl>
          </span>
        ) : (
          <span style={{ fontFamily: FONT.mono, fontSize: 12.5, fontWeight: 600, color: live ? T.green : T.dim, fontVariantNumeric: 'tabular-nums' }}>
            {job.state === 'queued' ? '—' : `${job.pct}%`}
          </span>
        )}
      </div>
      <div style={{ margin: '6px 0 5px' }}>
        <Track pct={job.state === 'queued' ? 0 : job.pct} state={job.state} h={3} />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7, fontFamily: FONT.mono, fontSize: 10, color: T.faint, letterSpacing: '0.01em' }}>
        <span style={{ color: meta.color, fontWeight: 600 }}>{job.done}{job.done ? '/' : ''}{job.total}</span>
        {job.speed && <><span style={{ opacity: 0.4 }}>·</span><span>{job.speed}</span></>}
        {job.eta && <><span style={{ opacity: 0.4 }}>·</span><span>ETA {job.eta}</span></>}
        {job.conns > 0 && <><span style={{ opacity: 0.4 }}>·</span><span>{job.conns}c</span></>}
        <span style={{ flex: 1 }} />
        <span style={{ opacity: 0.75 }}>{job.host}</span>
      </div>
    </div>
  );
}

function RecentRow({ job }) {
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(job.name);
  const failed = job.state === 'failed';
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ padding: '7px 14px', background: h ? 'rgba(255,255,255,0.035)' : 'transparent', display: 'flex', alignItems: 'center', gap: 8 }}>
      <StatusDot state={job.state} />
      <span style={{ fontSize: 12.5, fontWeight: 500, color: failed ? T.type : T.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flex: 1 }}>
        {stem}<span style={{ fontFamily: FONT.mono, fontWeight: 400, opacity: 0.7 }}>{ext}</span>
      </span>
      {failed ? (
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: T.oxblood, fontWeight: 600 }}>FAILED · {job.pct}%</span>
      ) : (
        <span style={{ display: 'flex', alignItems: 'center', gap: 6, fontFamily: FONT.mono, fontSize: 10, color: T.faint }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, color: T.dim }}>
            <Icon d={P.shield} size={11} sw={1.5} color={T.dim} /> {job.sha}
          </span>
          <span style={{ opacity: 0.4 }}>·</span>
          <span>{job.total}</span>
        </span>
      )}
    </div>
  );
}

function FooterTool({ d, label, badge, onClick, danger }) {
  const [h, setH] = useState(false);
  return (
    <button className="goh-btn" title={label} onClick={onClick}
      onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 5, padding: '5px 8px', borderRadius: 7,
        background: h ? T.fillH : 'transparent', color: danger ? T.oxblood : (h ? T.type : T.dim), position: 'relative' }}>
      <Icon d={d} size={14} />
      {label && <span style={{ fontSize: 11.5, fontWeight: 500, fontFamily: FONT.ui }}>{label}</span>}
      {badge != null && <span style={{ fontFamily: FONT.mono, fontSize: 9.5, fontWeight: 600, color: T.faint, marginLeft: 1 }}>{badge}</span>}
    </button>
  );
}

function TelemetryPopover() {
  const [jobs, setJobs] = useState(JOBS);
  const toggle = (id) => setJobs((js) => js.map((j) => j.id === id ? { ...j, state: j.state === 'active' ? 'paused' : 'active', speed: j.state === 'active' ? null : '5.1 MB/s' } : j));
  const live = jobs.filter((j) => ['active', 'paused', 'queued'].includes(j.state));
  const recent = jobs.filter((j) => ['completed', 'failed'].includes(j.state));
  const activeN = jobs.filter((j) => j.state === 'active').length;

  return (
    <Popover width={376} notchRight={74}>
      {/* ── instrument header ── */}
      <div style={{ padding: '12px 14px 13px', borderBottom: `0.5px solid ${T.hair}`, background: 'rgba(255,255,255,0.02)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
          <AppGlyph size={21} state={activeN ? 'active' : 'idle'} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 1, flex: 1, minWidth: 0 }}>
            <span style={{ fontSize: 13, fontWeight: 600, letterSpacing: '-0.01em' }}>gohd</span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: FONT.mono, fontSize: 9.5, color: T.green, fontWeight: 500 }}>
              <span style={{ width: 5, height: 5, borderRadius: 3, background: T.green, boxShadow: `0 0 6px ${T.green}` }} /> CONNECTED
            </span>
          </div>
          <span style={{ display: 'flex', gap: 1 }}>
            <Ctrl title="Add download"><Icon d={P.plus} size={16} sw={1.7} /></Ctrl>
            <Ctrl title="Preferences"><Icon d={P.gear} size={15} /></Ctrl>
          </span>
        </div>
        {/* throughput gauge */}
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 12, marginTop: 12 }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontFamily: FONT.mono, fontSize: 9, letterSpacing: '0.12em', color: T.faint, fontWeight: 600 }}>THROUGHPUT</span>
            <span style={{ display: 'flex', alignItems: 'baseline', gap: 4 }}>
              <span style={{ fontFamily: FONT.mono, fontSize: 23, fontWeight: 600, color: T.type, letterSpacing: '-0.02em', lineHeight: 1 }}>6.4</span>
              <span style={{ fontFamily: FONT.mono, fontSize: 11, color: T.dim, fontWeight: 500 }}>MB/s</span>
            </span>
          </div>
          <div style={{ flex: 1, display: 'flex', justifyContent: 'flex-end', paddingBottom: 1 }}>
            <Sparkline w={92} h={26} />
          </div>
        </div>
        {/* tiny stat strip */}
        <div style={{ display: 'flex', gap: 0, marginTop: 11 }}>
          {[['ACTIVE', activeN], ['QUEUED', '1'], ['CONN', '12'], ['DONE', '2']].map(([k, v], i) => (
            <div key={k} style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2, borderLeft: i ? `0.5px solid ${T.hair2}` : 'none', paddingLeft: i ? 10 : 0 }}>
              <span style={{ fontFamily: FONT.mono, fontSize: 14, fontWeight: 600, color: k === 'ACTIVE' ? T.green : T.type, fontVariantNumeric: 'tabular-nums' }}>{v}</span>
              <span style={{ fontFamily: FONT.mono, fontSize: 8.5, letterSpacing: '0.1em', color: T.faint, fontWeight: 600 }}>{k}</span>
            </div>
          ))}
        </div>
      </div>

      {/* ── clipboard command pill ── */}
      <div style={{ padding: '10px 14px 4px' }}>
        <button className="goh-btn" style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 8, padding: '8px 10px', borderRadius: 8, cursor: 'pointer',
          border: `0.5px solid ${T.greenDim}`, background: 'rgba(107,250,155,0.06)', color: T.type, textAlign: 'left' }}
          onMouseEnter={(e) => e.currentTarget.style.background = 'rgba(107,250,155,0.11)'}
          onMouseLeave={(e) => e.currentTarget.style.background = 'rgba(107,250,155,0.06)'}>
          <Icon d={P.clipboard} size={14} color={T.green} />
          <span style={{ display: 'flex', flexDirection: 'column', gap: 1, flex: 1, minWidth: 0 }}>
            <span style={{ fontSize: 11.5, fontWeight: 600 }}>Download clipboard URL</span>
            <span style={{ fontFamily: FONT.mono, fontSize: 9.5, color: T.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>huggingface.co/…/model-00003.safetensors</span>
          </span>
          <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 22, height: 22, borderRadius: 6, background: T.green }}>
            <Icon d={P.download} size={13} sw={2} color={T.ground} />
          </span>
        </button>
      </div>

      {/* ── live jobs ── */}
      <div style={{ paddingTop: 10 }}>
        <SectionLabel right={`${AGG.conns} conn`}>Transfers · {live.length}</SectionLabel>
        {live.map((j) => <DenseRow key={j.id} job={j} onToggle={toggle} />)}
      </div>

      {/* ── recent ── */}
      <div style={{ paddingTop: 11, paddingBottom: 4 }}>
        <SectionLabel right="48 tracked">Recent</SectionLabel>
        {recent.map((j) => <RecentRow key={j.id} job={j} />)}
      </div>

      {/* ── footer toolbar ── */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 1, padding: '7px 9px', borderTop: `0.5px solid ${T.hair}`, background: 'rgba(0,0,0,0.18)' }}>
        <FooterTool d={P.terminal} label="Terminal" />
        <FooterTool d={P.stack} label="Downloads" />
        <FooterTool d={P.shield} label="Trust" badge="41✓" />
        <span style={{ flex: 1 }} />
        <FooterTool d={P.gear} />
        <FooterTool d={P.quit} />
      </div>
    </Popover>
  );
}

// ── menu-bar icon states strip ─────────────────────────────────────────────
const ICON_STATES = [
  ['idle', 'Idle', 'No active downloads — green is held back.'],
  ['active', 'Active', 'One or more transfers live; the arrow lights phosphor.'],
  ['done', 'Done', 'Holds full green ~600ms after the last completes.'],
  ['paused', 'Paused', 'Arrow desaturates to 45%; user- or cellular-paused.'],
  ['error', 'Error', 'Arrow shifts to muted oxblood with a × overlay.'],
];

function IconStatesStrip() {
  return (
    <div style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', gap: 0 }}>
      <div style={{ fontFamily: FONT.mono, fontSize: 9.5, letterSpacing: '0.14em', color: T.faint, fontWeight: 600, marginBottom: 14 }}>MENU BAR · STATUS ITEM</div>
      {ICON_STATES.map(([st, label, desc], i) => (
        <div key={st} style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '11px 0', borderTop: i ? `0.5px solid ${T.hair2}` : 'none' }}>
          {/* menu bar fragment */}
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 11, padding: '5px 10px', borderRadius: 7,
            background: 'rgba(14,16,22,0.7)', boxShadow: `inset 0 0 0 0.5px ${T.hair}`, flexShrink: 0 }}>
            <Icon d={P.search} size={12} sw={1.6} color="rgba(244,237,224,0.7)" />
            <span style={{ position: 'relative', display: 'inline-flex', padding: '1px 4px', borderRadius: 5, background: st === 'active' || st === 'done' ? 'rgba(107,250,155,0.10)' : 'rgba(255,255,255,0.08)' }}>
              <AppGlyph size={17} state={st} bare />
              {st === 'error' && <span style={{ position: 'absolute', right: -1, top: -3, width: 9, height: 9, borderRadius: 5, background: T.oxblood, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon d={P.x} size={6} sw={3} color={T.ground} /></span>}
              {st === 'paused' && <span style={{ position: 'absolute', right: -2, top: -3, display: 'flex' }}><GlyphPause size={8} color={T.dim} /></span>}
            </span>
            <span style={{ fontFamily: FONT.mono, fontSize: 10.5, fontWeight: 500, opacity: 0.85 }}>9:41</span>
          </span>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
            <span style={{ fontSize: 12.5, fontWeight: 600, color: st === 'active' || st === 'done' ? T.green : T.type }}>{label}</span>
            <span style={{ fontSize: 11, color: T.dim, lineHeight: 1.3 }}>{desc}</span>
          </div>
        </div>
      ))}
    </div>
  );
}

// ── completion notification ────────────────────────────────────────────────
function TelemetryNotification() {
  return (
    <div style={{
      width: 340, borderRadius: 16, padding: '13px 15px', display: 'flex', gap: 12, alignItems: 'flex-start',
      fontFamily: FONT.ui, color: T.type,
      background: 'linear-gradient(180deg, rgba(30,33,42,0.9), rgba(18,20,27,0.92))',
      backdropFilter: 'blur(40px) saturate(170%)', WebkitBackdropFilter: 'blur(40px) saturate(170%)',
      boxShadow: `inset 0 0 0 0.5px ${T.hair}, 0 16px 50px rgba(0,0,0,0.55)`,
    }}>
      <AppGlyph size={32} state="done" />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 7 }}>
          <span style={{ fontSize: 13, fontWeight: 600 }}>Download complete</span>
          <span style={{ flex: 1 }} />
          <span style={{ fontFamily: FONT.mono, fontSize: 10, color: T.faint }}>now</span>
        </div>
        <div style={{ fontSize: 12.5, color: T.dim, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          sd-xl-base-1.0<span style={{ fontFamily: FONT.mono }}>.safetensors</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 8, fontFamily: FONT.mono, fontSize: 10, color: T.faint }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: T.green, fontWeight: 600 }}>
            <Icon d={P.shield} size={11} sw={1.6} color={T.green} /> recorded
          </span>
          <span style={{ opacity: 0.4 }}>·</span><span>6.94 GB</span>
          <span style={{ opacity: 0.4 }}>·</span><span>8c · 21s</span>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { TelemetryPopover, IconStatesStrip, TelemetryNotification });
