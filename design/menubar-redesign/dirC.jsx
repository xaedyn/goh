/* dirC.jsx — Direction C · "Focus" — active download as hero; the brand arrow IS the progress */
/* eslint-disable */

// The signature element: a progress lane whose leading edge is the goh arrowhead.
function ArrowProgress({ pct, big = false, state = 'active' }) {
  const c = useTheme();
  const h = big ? 7 : 4;
  const lane = big ? 18 : 11;
  const col = state === 'failed' ? c.oxblood : state === 'paused' ? c.dim : c.green;
  const live = state === 'active';
  const headW = big ? 13 : 9;
  return (
    <div style={{ position: 'relative', height: lane, display: 'flex', alignItems: 'center' }}>
      <div style={{ position: 'absolute', left: 0, right: 0, height: h, borderRadius: h / 2, background: c.track }} />
      <div style={{ position: 'absolute', left: 0, width: `${pct}%`, height: h, borderRadius: h / 2, background: col, overflow: 'hidden',
        boxShadow: live && c.glow ? `0 0 14px ${c.greenDim}` : 'none' }}>
        {live && <div style={{ position: 'absolute', top: 0, bottom: 0, width: '38%', background: 'linear-gradient(90deg, transparent, rgba(255,255,255,0.5), transparent)', animation: 'gohShimmer 2.4s linear infinite' }} />}
      </div>
      {pct > 2 && (
        <div style={{ position: 'absolute', left: `${pct}%`, transform: 'translateX(-48%)', display: 'flex', alignItems: 'center', filter: live && c.glow ? `drop-shadow(0 0 5px ${c.green})` : 'none' }}>
          <svg width={headW} height={headW} viewBox="0 0 12 12" style={{ display: 'block' }}>
            <path d="M3 1.5L9 6l-6 4.5z" fill={col} />
          </svg>
        </div>
      )}
    </div>
  );
}

function FocusStat({ label, value, accent }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <span style={{ fontFamily: FONT.mono, fontSize: 13, fontWeight: 600, color: accent ? T.green : T.type, fontVariantNumeric: 'tabular-nums', letterSpacing: '-0.01em' }}>{value}</span>
      <span style={{ fontFamily: FONT.mono, fontSize: 8.5, letterSpacing: '0.1em', color: T.faint, fontWeight: 600 }}>{label}</span>
    </div>
  );
}

function HeroCard({ job, onToggle }) {
  const [stem, ext] = splitName(job.name);
  const paused = job.state === 'paused';
  return (
    <div style={{ margin: '0 14px', padding: '15px 15px 16px', borderRadius: 13,
      background: 'linear-gradient(180deg, rgba(107,250,155,0.07), rgba(107,250,155,0.015))',
      boxShadow: `inset 0 0 0 0.5px ${T.greenDim}` }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 13 }}>
        <span style={{ fontFamily: FONT.mono, fontSize: 9, letterSpacing: '0.14em', color: T.green, fontWeight: 600, display: 'inline-flex', alignItems: 'center', gap: 5 }}>
          <span style={{ width: 5, height: 5, borderRadius: 3, background: T.green, boxShadow: `0 0 6px ${T.green}`, animation: 'gohPulse 1.8s ease-in-out infinite' }} />
          {paused ? 'PAUSED' : 'NOW PULLING'}
        </span>
        <span style={{ flex: 1 }} />
        <span style={{ display: 'flex', gap: 1, marginRight: -4 }}>
          <Ctrl title={paused ? 'Resume' : 'Pause'} onClick={() => onToggle(job.id)}>{paused ? <GlyphPlay /> : <GlyphPause />}</Ctrl>
          <Ctrl title="Copy URL"><Icon d={P.link} size={13} /></Ctrl>
          <Ctrl title="Remove" danger><GlyphTrash /></Ctrl>
        </span>
      </div>
      <div style={{ fontSize: 15.5, fontWeight: 600, color: T.type, letterSpacing: '-0.015em', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {stem}<span style={{ fontFamily: FONT.mono, color: T.dim, fontWeight: 400, fontSize: 13 }}>{ext}</span>
      </div>
      <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4, marginTop: 4, fontFamily: FONT.mono, fontSize: 10, color: T.faint }}>
        <Icon d={P.globe} size={10} sw={1.4} color={T.faint} />{job.host}
      </div>

      {/* big percent + arrow progress */}
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 10, marginTop: 15, marginBottom: 11 }}>
        <span style={{ fontFamily: FONT.mono, fontSize: 34, fontWeight: 600, color: T.type, lineHeight: 0.85, letterSpacing: '-0.03em' }}>{job.pct}<span style={{ fontSize: 17, color: T.dim }}>%</span></span>
        <span style={{ flex: 1, paddingBottom: 5 }}>
          <ArrowProgress pct={job.pct} big state={job.state} />
        </span>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 0, paddingTop: 13, borderTop: `0.5px solid ${T.hair2}` }}>
        <span style={{ flex: 1 }}><FocusStat label="DOWNLOADED" value={`${job.done}/${job.total}`} /></span>
        <span style={{ flex: 1 }}><FocusStat label="SPEED" value={job.speed || '—'} accent /></span>
        <span style={{ flex: 1 }}><FocusStat label="ETA" value={job.eta || '—'} /></span>
        <span style={{ width: 46 }}><FocusStat label="CONN" value={`${job.conns}`} /></span>
      </div>
    </div>
  );
}

function MiniRow({ job, onToggle }) {
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(job.name);
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 16px', background: h ? 'rgba(255,255,255,0.035)' : 'transparent' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontSize: 12.5, fontWeight: 500, color: T.type, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flex: 1 }}>
            {stem}<span style={{ fontFamily: FONT.mono, color: T.dim, fontWeight: 400 }}>{ext}</span>
          </span>
          <span style={{ fontFamily: FONT.mono, fontSize: 10, color: job.state === 'queued' ? T.faint : T.dim, fontWeight: 500 }}>
            {job.state === 'queued' ? 'queued' : `${job.pct}%`}
          </span>
        </div>
        <div style={{ marginTop: 7 }}><ArrowProgress pct={job.state === 'queued' ? 0 : job.pct} state={job.state} /></div>
      </div>
      {h && (
        <span style={{ display: 'flex', gap: 1 }}>
          {job.state === 'active' && <Ctrl title="Pause" onClick={() => onToggle(job.id)}><GlyphPause /></Ctrl>}
          {job.state === 'paused' && <Ctrl title="Resume" onClick={() => onToggle(job.id)}><GlyphPlay /></Ctrl>}
          <Ctrl title="Remove" danger><GlyphTrash /></Ctrl>
        </span>
      )}
    </div>
  );
}

function RecentMini({ job }) {
  const [stem, ext] = splitName(job.name);
  const failed = job.state === 'failed';
  return (
    <div className="goh-row-hit" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 16px' }}>
      <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 14, height: 14, borderRadius: 7,
        background: failed ? 'transparent' : 'transparent', boxShadow: `inset 0 0 0 1px ${failed ? T.oxblood : T.ghost}`, flexShrink: 0 }}>
        {failed ? <Icon d={P.x} size={8} sw={2.6} color={T.oxblood} /> : <Icon d={P.check} size={9} sw={2.4} color={T.dim} />}
      </span>
      <span style={{ fontSize: 12, fontWeight: 500, color: T.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flex: 1 }}>
        {stem}<span style={{ fontFamily: FONT.mono, fontWeight: 400, opacity: 0.7 }}>{ext}</span>
      </span>
      <span style={{ fontFamily: FONT.mono, fontSize: 9.5, color: T.faint }}>{failed ? 'failed' : job.total}</span>
    </div>
  );
}

function FocusFootTool({ d, label, danger, onClick }) {
  const [h, setH] = useState(false);
  return (
    <button className="goh-btn" title={label} onClick={onClick} onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 5, padding: '6px 9px', borderRadius: 7,
        background: h ? T.fillH : 'transparent', color: danger ? T.oxblood : (h ? T.type : T.dim) }}>
      <Icon d={d} size={14} />{label && <span style={{ fontSize: 11.5, fontWeight: 500, fontFamily: FONT.ui }}>{label}</span>}
    </button>
  );
}

function FocusPopover() {
  const [jobs, setJobs] = useState(JOBS);
  const toggle = (id) => setJobs((js) => js.map((j) => j.id === id ? { ...j, state: j.state === 'active' ? 'paused' : 'active', speed: j.state === 'active' ? null : '5.1 MB/s' } : j));
  const actives = jobs.filter((j) => j.state === 'active');
  const hero = actives[0] || jobs.find((j) => j.state === 'paused') || jobs[0];
  const others = jobs.filter((j) => ['active', 'paused', 'queued'].includes(j.state) && j.id !== hero.id);
  const recent = jobs.filter((j) => ['completed', 'failed'].includes(j.state));

  return (
    <Popover width={372} notchRight={74}>
      {/* compact header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '12px 14px 13px' }}>
        <AppGlyph size={20} state={actives.length ? 'active' : 'idle'} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 1, flex: 1 }}>
          <span style={{ fontSize: 13, fontWeight: 600 }}>goh</span>
          <span style={{ fontFamily: FONT.mono, fontSize: 9.5, color: T.dim }}><span style={{ color: T.green }}>{actives.length} active</span> · {AGG.speed} · 48 tracked</span>
        </div>
        <Ctrl title="Add download"><Icon d={P.plus} size={16} sw={1.7} /></Ctrl>
        <Ctrl title="Preferences"><Icon d={P.gear} size={15} /></Ctrl>
      </div>

      {/* hero */}
      <HeroCard job={hero} onToggle={toggle} />

      {/* clipboard quick action */}
      <div style={{ padding: '13px 14px 3px' }}>
        <button className="goh-btn" style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 8, padding: '8px 11px', borderRadius: 9, cursor: 'pointer',
          border: 'none', background: 'rgba(255,255,255,0.045)', color: T.type, textAlign: 'left' }}
          onMouseEnter={(e) => e.currentTarget.style.background = 'rgba(255,255,255,0.08)'}
          onMouseLeave={(e) => e.currentTarget.style.background = 'rgba(255,255,255,0.045)'}>
          <Icon d={P.clipboard} size={14} color={T.green} />
          <span style={{ fontSize: 11.5, fontWeight: 600, flex: 1 }}>Download clipboard URL</span>
          <span style={{ fontFamily: FONT.mono, fontSize: 9, color: T.faint, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: 130 }}>…model-00003.safetensors</span>
          <Icon d={P.chevR} size={13} color={T.dim} />
        </button>
      </div>

      {/* others */}
      <div style={{ marginTop: 8 }}>
        <div style={{ fontFamily: FONT.mono, fontSize: 9, letterSpacing: '0.13em', color: T.faint, fontWeight: 600, padding: '0 16px 3px' }}>QUEUE · {others.length}</div>
        {others.map((j) => <MiniRow key={j.id} job={j} onToggle={toggle} />)}
      </div>

      {/* recent */}
      <div style={{ marginTop: 9, paddingBottom: 5 }}>
        <div style={{ display: 'flex', alignItems: 'center', padding: '0 16px 4px' }}>
          <span style={{ fontFamily: FONT.mono, fontSize: 9, letterSpacing: '0.13em', color: T.faint, fontWeight: 600 }}>RECENT</span>
          <span style={{ flex: 1 }} />
          <span style={{ fontFamily: FONT.ui, fontSize: 10.5, fontWeight: 600, color: T.dim, cursor: 'pointer' }}>See all →</span>
        </div>
        {recent.map((j) => <RecentMini key={j.id} job={j} />)}
      </div>

      {/* footer */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 1, padding: '7px 9px', borderTop: `0.5px solid ${T.hair}`, background: 'rgba(0,0,0,0.18)' }}>
        <FocusFootTool d={P.terminal} label="Terminal" />
        <FocusFootTool d={P.shield} label="Trust" />
        <span style={{ flex: 1 }} />
        <FocusFootTool d={P.stack} />
        <FocusFootTool d={P.quit} />
      </div>
    </Popover>
  );
}

// ── menu-bar icon states (Focus — arrow-forward) ───────────────────────────
function IconStatesStripC() {
  return (
    <div style={{ padding: '18px 20px' }}>
      <div style={{ fontFamily: FONT.mono, fontSize: 9.5, letterSpacing: '0.14em', color: T.faint, fontWeight: 600, marginBottom: 14 }}>MENU BAR · STATUS ITEM</div>
      {ICON_STATES.map(([st, label, desc], i) => (
        <div key={st} style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '11px 0', borderTop: i ? `0.5px solid ${T.hair2}` : 'none' }}>
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

// ── completion notification (Focus) ────────────────────────────────────────
function FocusNotification() {
  return (
    <div style={{
      width: 340, borderRadius: 16, padding: '14px 16px', display: 'flex', gap: 12, alignItems: 'center',
      fontFamily: FONT.ui, color: T.type,
      background: 'linear-gradient(180deg, rgba(30,33,42,0.9), rgba(18,20,27,0.92))',
      backdropFilter: 'blur(40px) saturate(170%)', WebkitBackdropFilter: 'blur(40px) saturate(170%)',
      boxShadow: `inset 0 0 0 0.5px ${T.hair}, 0 16px 50px rgba(0,0,0,0.55)`,
    }}>
      <div style={{ position: 'relative', width: 40, height: 40, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="40" height="40" viewBox="0 0 40 40" style={{ position: 'absolute' }}>
          <circle cx="20" cy="20" r="17" fill="none" stroke="rgba(255,255,255,0.1)" strokeWidth="2.5" />
          <circle cx="20" cy="20" r="17" fill="none" stroke={T.green} strokeWidth="2.5" strokeLinecap="round" strokeDasharray="106.8" strokeDashoffset="0" transform="rotate(-90 20 20)" style={{ filter: `drop-shadow(0 0 4px ${T.green})` }} />
        </svg>
        <GohArrow w={15} color={T.green} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 7 }}>
          <span style={{ fontSize: 13, fontWeight: 600 }}>Complete</span>
          <span style={{ fontFamily: FONT.mono, fontSize: 9.5, color: T.green, fontWeight: 600, letterSpacing: '0.08em' }}>100%</span>
          <span style={{ flex: 1 }} />
          <span style={{ fontFamily: FONT.mono, fontSize: 10, color: T.faint }}>now</span>
        </div>
        <div style={{ fontSize: 12.5, color: T.dim, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          sd-xl-base-1.0<span style={{ fontFamily: FONT.mono }}>.safetensors</span>
        </div>
        <div style={{ marginTop: 5, fontFamily: FONT.mono, fontSize: 9.5, color: T.faint }}>6.94 GB · recorded · 8c · 21s</div>
      </div>
    </div>
  );
}

Object.assign(window, { FocusPopover, IconStatesStripC, FocusNotification, ArrowProgress });
