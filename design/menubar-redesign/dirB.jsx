/* dirB.jsx — Direction B · "Ledger" — editorial, provenance-forward */
/* eslint-disable */

function LedgerHead({ children, no }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '0 16px', marginBottom: 9 }}>
      <span style={{ fontFamily: FONT.mono, fontSize: 9.5, fontWeight: 600, letterSpacing: '0.18em', color: T.dim, textTransform: 'uppercase' }}>{children}</span>
      <span style={{ flex: 1, height: 0.5, background: T.hair, transform: 'translateY(-3px)' }} />
      {no && <span style={{ fontFamily: FONT.serif, fontStyle: 'italic', fontSize: 12, color: T.faint }}>No. {no}</span>}
    </div>
  );
}

function LedgerActiveRow({ job, idx, onToggle }) {
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(job.name);
  const live = job.state === 'active';
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ padding: '10px 16px 12px', background: h ? 'rgba(255,255,255,0.03)' : 'transparent', position: 'relative' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: live ? T.green : T.faint, fontWeight: 600, width: 16, flexShrink: 0 }}>{String(idx).padStart(2, '0')}</span>
        <span style={{ fontSize: 13, fontWeight: 500, color: T.type, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flex: 1, letterSpacing: '-0.005em' }}>
          {stem}<span style={{ fontFamily: FONT.mono, color: T.dim, fontWeight: 400 }}>{ext}</span>
        </span>
        {h && (live || job.state === 'paused') ? (
          <span style={{ display: 'flex', gap: 1, marginRight: -4 }}>
            {live && <Ctrl title="Pause" onClick={() => onToggle(job.id)}><GlyphPause /></Ctrl>}
            {job.state === 'paused' && <Ctrl title="Resume" onClick={() => onToggle(job.id)}><GlyphPlay /></Ctrl>}
            <Ctrl title="Copy URL"><Icon d={P.link} size={13} /></Ctrl>
            <Ctrl title="Remove" danger><GlyphTrash /></Ctrl>
          </span>
        ) : (
          <span style={{ fontFamily: FONT.mono, fontSize: 13, fontWeight: 600, color: live ? T.green : T.dim, fontVariantNumeric: 'tabular-nums' }}>
            {job.state === 'queued' ? 'queued' : `${job.pct}%`}
          </span>
        )}
      </div>
      <div style={{ margin: '8px 0 8px', paddingLeft: 26 }}>
        <Track pct={job.state === 'queued' ? 0 : job.pct} state={job.state} h={2} radius={1} />
      </div>
      <div style={{ paddingLeft: 26, display: 'flex', alignItems: 'center', gap: 7, fontFamily: FONT.mono, fontSize: 10, color: T.faint }}>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: T.dim }}><Icon d={P.globe} size={10} sw={1.4} color={T.faint} />{job.host}</span>
        <span style={{ opacity: 0.4 }}>·</span>
        <span style={{ color: STATE_META[job.state].color }}>{job.done}{job.done ? '/' : ''}{job.total}</span>
        {job.speed && <><span style={{ opacity: 0.4 }}>·</span><span>{job.speed}</span></>}
        {job.eta && <><span style={{ opacity: 0.4 }}>·</span><span>{job.eta}</span></>}
        {job.conns > 0 && <><span style={{ opacity: 0.4 }}>·</span><span>{job.conns}c</span></>}
      </div>
    </div>
  );
}

function LedgerProvRow({ job }) {
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(job.name);
  const failed = job.state === 'failed';
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ padding: '9px 16px', background: h ? 'rgba(255,255,255,0.03)' : 'transparent' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <span style={{ fontSize: 12.5, fontWeight: 500, color: failed ? T.type : T.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flexShrink: 1 }}>
          {stem}<span style={{ fontFamily: FONT.mono, fontWeight: 400, opacity: 0.75 }}>{ext}</span>
        </span>
        <span style={{ flex: 1, borderBottom: `1px dotted ${T.ghost}`, transform: 'translateY(-3px)', minWidth: 12 }} />
        {failed ? (
          <span style={{ fontFamily: FONT.mono, fontSize: 10, color: T.oxblood, fontWeight: 600, display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <Icon d={P.x} size={10} sw={2.4} color={T.oxblood} /> failed
          </span>
        ) : (
          <span style={{ fontFamily: FONT.mono, fontSize: 10.5, color: T.dim, fontWeight: 500, display: 'inline-flex', alignItems: 'center', gap: 5, flexShrink: 0 }}>
            <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 13, height: 13, borderRadius: 7, boxShadow: `inset 0 0 0 1px ${T.dim}` }}>
              <Icon d={P.check} size={8} sw={2.6} color={T.type} />
            </span>
            {job.verified}
          </span>
        )}
      </div>
      <div style={{ marginTop: 4, fontFamily: FONT.mono, fontSize: 9.5, color: T.faint, letterSpacing: '0.01em', display: 'flex', gap: 7 }}>
        {!failed && <span style={{ color: 'rgba(244,237,224,0.42)' }}>sha256:{job.sha}</span>}
        {!failed && <span style={{ opacity: 0.4 }}>·</span>}
        <span>{job.total}</span>
        <span style={{ opacity: 0.4 }}>·</span>
        <span style={{ opacity: 0.8 }}>{job.host}</span>
      </div>
    </div>
  );
}

function LedgerFootLink({ d, label, onClick, danger }) {
  const [h, setH] = useState(false);
  return (
    <button className="goh-btn" onClick={onClick} onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ border: 'none', background: 'transparent', cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 5,
        padding: '4px 2px', color: danger ? T.oxblood : (h ? T.type : T.dim), fontFamily: FONT.ui, fontSize: 11.5, fontWeight: 500 }}>
      <Icon d={d} size={13} /> {label}
    </button>
  );
}

function LedgerPopover() {
  const [jobs, setJobs] = useState(JOBS);
  const toggle = (id) => setJobs((js) => js.map((j) => j.id === id ? { ...j, state: j.state === 'active' ? 'paused' : 'active', speed: j.state === 'active' ? null : '5.1 MB/s' } : j));
  const live = jobs.filter((j) => ['active', 'paused', 'queued'].includes(j.state));
  const recent = jobs.filter((j) => ['completed', 'failed'].includes(j.state));

  return (
    <Popover width={380} notchRight={74}>
      {/* ── masthead ── */}
      <div style={{ padding: '14px 16px 13px' }}>
        <div style={{ display: 'flex', alignItems: 'flex-start' }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <WordmarkGoh h={27} />
            <div style={{ fontFamily: FONT.mono, fontSize: 9, letterSpacing: '0.16em', color: T.faint, fontWeight: 600, marginTop: 9, textTransform: 'uppercase' }}>
              Provenance ledger · <span style={{ color: T.green }}>gohd live</span>
            </div>
          </div>
          <span style={{ display: 'flex', gap: 1 }}>
            <Ctrl title="Add download"><Icon d={P.plus} size={16} sw={1.7} /></Ctrl>
            <Ctrl title="Preferences"><Icon d={P.gear} size={15} /></Ctrl>
          </span>
        </div>
      </div>
      <div style={{ height: 0.5, background: T.hair, margin: '0 16px 13px' }} />

      {/* ── clipboard line ── */}
      <div style={{ padding: '0 16px 14px' }}>
        <button className="goh-btn" style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 9, padding: '9px 11px', borderRadius: 9, cursor: 'pointer',
          border: `0.5px solid ${T.hair}`, background: 'rgba(255,255,255,0.03)', color: T.type, textAlign: 'left' }}
          onMouseEnter={(e) => e.currentTarget.style.background = 'rgba(107,250,155,0.08)'}
          onMouseLeave={(e) => e.currentTarget.style.background = 'rgba(255,255,255,0.03)'}>
          <Icon d={P.clipboard} size={15} color={T.green} />
          <span style={{ display: 'flex', flexDirection: 'column', gap: 1, flex: 1, minWidth: 0 }}>
            <span style={{ fontSize: 12, fontWeight: 600 }}>Pull clipboard URL</span>
            <span style={{ fontFamily: FONT.mono, fontSize: 9.5, color: T.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>huggingface.co/…/model-00003.safetensors</span>
          </span>
          <Icon d={P.chevR} size={14} color={T.dim} />
        </button>
      </div>

      {/* ── active ── */}
      <LedgerHead no={String(live.length).padStart(2, '0')}>In transit</LedgerHead>
      <div>{live.map((j, i) => <LedgerActiveRow key={j.id} job={j} idx={i + 1} onToggle={toggle} />)}</div>

      {/* ── provenance ── */}
      <div style={{ marginTop: 13 }}>
        <LedgerHead no="48">Recorded</LedgerHead>
        <div>{recent.map((j) => <LedgerProvRow key={j.id} job={j} />)}</div>
      </div>

      {/* trust summary ribbon */}
      <div style={{ margin: '12px 16px 0', padding: '9px 12px', borderRadius: 9, background: 'rgba(255,255,255,0.025)', boxShadow: `inset 0 0 0 0.5px ${T.hair2}`,
        display: 'flex', alignItems: 'center', gap: 10 }}>
        <Icon d={P.shield} size={15} sw={1.5} color={T.dim} />
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: T.dim, flex: 1 }}>
          <span style={{ color: T.type, fontWeight: 600 }}>48</span> tracked · <span style={{ color: T.type, fontWeight: 600 }}>41</span> verified · <span style={{ color: T.type, fontWeight: 600 }}>7</span> download-only
        </span>
        <span style={{ fontFamily: FONT.ui, fontSize: 11, fontWeight: 600, color: T.green, cursor: 'pointer' }}>Open →</span>
      </div>

      {/* ── footer ── */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '11px 16px 12px', marginTop: 11, borderTop: `0.5px solid ${T.hair}` }}>
        <LedgerFootLink d={P.terminal} label="Terminal" />
        <LedgerFootLink d={P.stack} label="Downloads" />
        <span style={{ flex: 1 }} />
        <LedgerFootLink d={P.quit} label="Quit" danger />
      </div>
    </Popover>
  );
}

// ── menu-bar icon states (Ledger variant — serif-forward chips) ────────────
function IconStatesStripB() {
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

// ── completion notification (Ledger) ───────────────────────────────────────
function LedgerNotification() {
  return (
    <div style={{
      width: 340, borderRadius: 16, padding: '14px 16px',
      fontFamily: FONT.ui, color: T.type,
      background: 'linear-gradient(180deg, rgba(30,33,42,0.9), rgba(18,20,27,0.92))',
      backdropFilter: 'blur(40px) saturate(170%)', WebkitBackdropFilter: 'blur(40px) saturate(170%)',
      boxShadow: `inset 0 0 0 0.5px ${T.hair}, 0 16px 50px rgba(0,0,0,0.55)`,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
        <WordmarkGoh h={17} />
        <span style={{ flex: 1 }} />
        <span style={{ fontFamily: FONT.mono, fontSize: 9.5, letterSpacing: '0.12em', color: T.green, fontWeight: 600 }}>RECORDED · NOW</span>
      </div>
      <div style={{ height: 0.5, background: T.hair, margin: '11px 0' }} />
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <span style={{ fontSize: 13, fontWeight: 500 }}>sd-xl-base-1.0<span style={{ fontFamily: FONT.mono, color: T.dim }}>.safetensors</span></span>
        <span style={{ flex: 1, borderBottom: `1px dotted ${T.ghost}`, transform: 'translateY(-3px)' }} />
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontFamily: FONT.mono, fontSize: 10, color: T.dim }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 13, height: 13, borderRadius: 7, boxShadow: `inset 0 0 0 1px ${T.dim}` }}><Icon d={P.check} size={8} sw={2.6} color={T.type} /></span>
          verified
        </span>
      </div>
      <div style={{ marginTop: 5, fontFamily: FONT.mono, fontSize: 9.5, color: T.faint }}>sha256:a1f3…9c20 · 6.94 GB · 8 connections · 21s</div>
    </div>
  );
}

Object.assign(window, { LedgerPopover, IconStatesStripB, LedgerNotification });
