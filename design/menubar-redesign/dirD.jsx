/* dirD.jsx — Direction D · "Manifest" — the chosen hybrid, theme-aware (dark + light).
   Props (all optional; canvas uses dark defaults): jobs, daemon, density. */
/* eslint-disable */

function ManifestSpark({ w = 70, h = 18, dim = false }) {
  const c = useTheme();
  const pts = [3,5,4,7,6,9,8,11,9,12,10,13,11,10,12,9,11,10];
  const max = 14, step = w / (pts.length - 1);
  const d = pts.map((p, i) => `${i ? 'L' : 'M'}${(i * step).toFixed(1)} ${(h - (p / max) * h).toFixed(1)}`).join(' ');
  const col = dim ? c.dim : c.green;
  return (
    <svg width={w} height={h} style={{ display: 'block', overflow: 'visible', opacity: dim ? 0.5 : 1 }}>
      <path d={`${d} L${w} ${h} L0 ${h} Z`} fill={col} opacity="0.1" />
      <path d={d} fill="none" stroke={col} strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx={w} cy={h - (pts[pts.length - 1] / max) * h} r="1.8" fill={col} />
    </svg>
  );
}

function ManifestHead({ children, no }) {
  const c = useTheme();
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, padding: '0 16px', marginBottom: 8 }}>
      <span style={{ fontFamily: FONT.mono, fontSize: 9.5, fontWeight: 600, letterSpacing: '0.18em', color: c.dim, textTransform: 'uppercase' }}>{children}</span>
      <span style={{ flex: 1, height: 0.5, background: c.hair, transform: 'translateY(-3px)' }} />
      {no && <span style={{ fontFamily: FONT.serif, fontStyle: 'italic', fontSize: 12, color: c.faint }}>No. {no}</span>}
    </div>
  );
}

function EmptyLine({ children }) {
  const c = useTheme();
  return <div style={{ padding: '4px 16px 2px', fontSize: 12, color: c.faint, fontStyle: 'italic', fontFamily: FONT.serif }}>{children}</div>;
}

function ManifestActiveRow({ job, idx, onToggle, comfy = true }) {
  const c = useTheme();
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(job.name);
  const live = job.state === 'active';
  const stateColor = live ? c.green : job.state === 'failed' ? c.oxblood : c.dim;
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ padding: comfy ? '9px 16px 11px' : '6px 16px 7px', background: h ? c.rowHover : 'transparent' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: live ? c.green : c.faint, fontWeight: 600, width: 15, flexShrink: 0 }}>{String(idx).padStart(2, '0')}</span>
        <span style={{ fontSize: 13, fontWeight: 500, color: c.type, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flex: 1, letterSpacing: '-0.005em' }}>
          {stem}<span style={{ fontFamily: FONT.mono, color: c.dim, fontWeight: 400 }}>{ext}</span>
        </span>
        {h && (live || job.state === 'paused') ? (
          <span style={{ display: 'flex', gap: 1, marginRight: -4 }}>
            {live && <Ctrl title="Pause" onClick={() => onToggle(job.id)}><GlyphPause /></Ctrl>}
            {job.state === 'paused' && <Ctrl title="Resume" onClick={() => onToggle(job.id)}><GlyphPlay color={c.green} /></Ctrl>}
            <Ctrl title="Copy URL"><Icon d={P.link} size={13} /></Ctrl>
            <Ctrl title="Remove" danger><GlyphTrash /></Ctrl>
          </span>
        ) : (
          <span style={{ fontFamily: FONT.mono, fontSize: 13, fontWeight: 600, color: live ? c.green : c.dim, fontVariantNumeric: 'tabular-nums' }}>
            {job.state === 'queued' ? 'queued' : `${job.pct}%`}
          </span>
        )}
      </div>
      <div style={{ margin: comfy ? '7px 0 7px' : '5px 0 5px', paddingLeft: 25 }}>
        <ArrowProgress pct={job.state === 'queued' ? 0 : job.pct} state={job.state} />
      </div>
      <div style={{ paddingLeft: 25, display: 'flex', alignItems: 'center', gap: 7, fontFamily: FONT.mono, fontSize: 10, color: c.faint }}>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: c.dim }}><Icon d={P.globe} size={10} sw={1.4} color={c.faint} />{job.host}</span>
        <span style={{ opacity: 0.4 }}>·</span>
        <span style={{ color: stateColor }}>{job.done}{job.done ? '/' : ''}{job.total}</span>
        {job.speed && <><span style={{ opacity: 0.4 }}>·</span><span>{job.speed}</span></>}
        {job.eta && <><span style={{ opacity: 0.4 }}>·</span><span>ETA {job.eta}</span></>}
        {job.conns > 0 && <><span style={{ opacity: 0.4 }}>·</span><span>{job.conns}c</span></>}
      </div>
    </div>
  );
}

function ManifestProvRow({ job, comfy = true }) {
  const c = useTheme();
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(job.name);
  const failed = job.state === 'failed';
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ padding: comfy ? '8px 16px' : '5px 16px', background: h ? c.rowHover : 'transparent' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <span style={{ fontSize: 12.5, fontWeight: 500, color: failed ? c.type : c.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0, flexShrink: 1 }}>
          {stem}<span style={{ fontFamily: FONT.mono, fontWeight: 400, opacity: 0.75 }}>{ext}</span>
        </span>
        <span style={{ flex: 1, borderBottom: `1px dotted ${c.ghost}`, transform: 'translateY(-3px)', minWidth: 12 }} />
        {failed ? (
          <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.oxblood, fontWeight: 600, display: 'inline-flex', alignItems: 'center', gap: 4 }}>
            <Icon d={P.x} size={10} sw={2.4} color={c.oxblood} /> failed
          </span>
        ) : (
          <span style={{ fontFamily: FONT.mono, fontSize: 10.5, color: c.dim, fontWeight: 500, display: 'inline-flex', alignItems: 'center', gap: 5, flexShrink: 0 }}>
            <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 13, height: 13, borderRadius: 7, boxShadow: `inset 0 0 0 1px ${c.dim}` }}>
              <Icon d={P.check} size={8} sw={2.6} color={c.type} />
            </span>
            {job.verified}
          </span>
        )}
      </div>
      {comfy && (
        <div style={{ marginTop: 4, fontFamily: FONT.mono, fontSize: 9.5, color: c.faint, letterSpacing: '0.01em', display: 'flex', gap: 7 }}>
          {!failed && <span style={{ color: c.sha }}>sha256:{job.sha}</span>}
          {!failed && <span style={{ opacity: 0.4 }}>·</span>}
          <span>{job.total}</span>
          <span style={{ opacity: 0.4 }}>·</span>
          <span style={{ opacity: 0.8 }}>{job.host}</span>
        </div>
      )}
    </div>
  );
}

function ManifestFootLink({ d, label, onClick, danger }) {
  const c = useTheme();
  const [h, setH] = useState(false);
  return (
    <button className="goh-btn" onClick={onClick} onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ border: 'none', background: 'transparent', cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 5,
        padding: '4px 2px', color: danger ? c.oxblood : (h ? c.type : c.dim), fontFamily: FONT.ui, fontSize: 11.5, fontWeight: 500 }}>
      <Icon d={d} size={13} /> {label}
    </button>
  );
}

function ManifestPopover({ jobs = JOBS, daemon = 'connected', density = 'comfortable' } = {}) {
  const c = useTheme();
  const [local, setLocal] = useState(jobs);
  useEffect(() => { setLocal(jobs); }, [jobs]);
  const toggle = (id) => setLocal((js) => js.map((j) => j.id === id ? { ...j, state: j.state === 'active' ? 'paused' : 'active', speed: j.state === 'active' ? null : '5.1 MB/s' } : j));
  const live = local.filter((j) => ['active', 'paused', 'queued'].includes(j.state));
  const recent = local.filter((j) => ['completed', 'failed'].includes(j.state));
  const activeN = local.filter((j) => j.state === 'active').length;
  const comfy = density !== 'compact';
  const empty = local.length === 0;
  const failed = daemon === 'failed';
  const reconnecting = daemon === 'reconnecting';

  const statusLine = failed
    ? <span style={{ color: c.oxblood }}>gohd unavailable · run doctor</span>
    : reconnecting
      ? <span style={{ color: c.dim }}>reconnecting to gohd…</span>
      : null;

  return (
    <Popover width={384} notchRight={74}>
      {/* ── masthead ── */}
      <div style={{ padding: '14px 16px 12px' }}>
        <div style={{ display: 'flex', alignItems: 'flex-start' }}>
          <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
            <WordmarkGoh h={26} type={c.type} accent={c.wordmarkArrow} />
            {statusLine && <div style={{ fontFamily: FONT.mono, fontSize: 9, letterSpacing: '0.15em', color: c.faint, fontWeight: 600, marginTop: 9, textTransform: 'uppercase' }}>
              {statusLine}
            </div>}
          </div>
          <span style={{ display: 'flex', gap: 1 }}>
            <Ctrl title="Add download"><Icon d={P.plus} size={16} sw={1.7} /></Ctrl>
            <Ctrl title="Preferences"><Icon d={P.gear} size={15} /></Ctrl>
          </span>
        </div>
      </div>

      {failed ? (
        /* ── recovery card (trust verbs still read from disk) ── */
        <div style={{ margin: '0 16px 14px', padding: '12px 13px', borderRadius: 10, background: c.recovery, boxShadow: `inset 0 0 0 0.5px ${c.recoveryBorder}` }}>
          <div style={{ display: 'flex', alignItems: 'flex-start', gap: 9 }}>
            <Icon d={P.pulse} size={15} sw={1.6} color={c.oxblood} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 12.5, fontWeight: 600, color: c.type }}>Background service unreachable</div>
              <div style={{ fontFamily: FONT.mono, fontSize: 9.5, color: c.dim, marginTop: 3 }}>Run goh doctor for exact recovery. Your ledger below still reads offline.</div>
            </div>
          </div>
          <div style={{ display: 'flex', gap: 8, marginTop: 11 }}>
            <button className="goh-btn" style={{ flex: 1, padding: '7px 0', borderRadius: 7, border: 'none', background: c.recoveryBtn, color: c.type, fontSize: 12, fontWeight: 600, cursor: 'pointer' }}>Open doctor</button>
            <button className="goh-btn" style={{ flex: 1, padding: '7px 0', borderRadius: 7, border: `0.5px solid ${c.hair}`, background: c.fill, color: c.dim, fontSize: 11.5, fontWeight: 500, cursor: 'pointer' }}>Copy command</button>
          </div>
        </div>
      ) : (
        <>
          {/* ── instrument strip ── */}
          <div style={{ margin: '0 16px 13px', padding: '10px 12px', borderRadius: 10, background: c.panel, boxShadow: `inset 0 0 0 0.5px ${c.hair2}`,
            display: 'flex', alignItems: 'center', gap: 12, opacity: reconnecting ? 0.7 : 1 }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 4 }}>
              <span style={{ fontFamily: FONT.mono, fontSize: 19, fontWeight: 600, color: empty ? c.dim : c.type, letterSpacing: '-0.02em', lineHeight: 1 }}>{empty ? '0.0' : '6.4'}</span>
              <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.dim, fontWeight: 500 }}>MB/s</span>
            </div>
            <ManifestSpark w={66} h={20} dim={empty || reconnecting} />
            <span style={{ flex: 1 }} />
            <div style={{ display: 'flex', gap: 11, fontFamily: FONT.mono, fontSize: 9.5, color: c.faint, fontWeight: 500 }}>
              {[['active', activeN, activeN ? c.green : c.dim], ['queued', live.filter((j) => j.state === 'queued').length, c.dim], ['conn', empty ? 0 : 12, c.dim]].map(([k, v, col]) => (
                <span key={k} style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 2 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 600, color: col, fontVariantNumeric: 'tabular-nums' }}>{v}</span>
                  <span style={{ fontSize: 8, letterSpacing: '0.08em', textTransform: 'uppercase' }}>{k}</span>
                </span>
              ))}
            </div>
          </div>

          {/* ── clipboard pull ── */}
          <div style={{ padding: '0 16px 14px' }}>
            <button className="goh-btn" style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 9, padding: empty ? '12px 11px' : '9px 11px', borderRadius: 9, cursor: 'pointer',
              border: `0.5px solid ${c.ctaBorder}`, background: c.ctaTint, color: c.type, textAlign: 'left' }}
              onMouseEnter={(e) => e.currentTarget.style.background = c.ctaTintH}
              onMouseLeave={(e) => e.currentTarget.style.background = c.ctaTint}>
              <Icon d={P.clipboard} size={15} color={c.green} />
              <span style={{ display: 'flex', flexDirection: 'column', gap: 1, flex: 1, minWidth: 0 }}>
                <span style={{ fontSize: 12, fontWeight: 600 }}>{empty ? 'Paste a URL to begin' : 'Pull clipboard URL'}</span>
                <span style={{ fontFamily: FONT.mono, fontSize: 9.5, color: c.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{empty ? 'or drag a link onto the menu bar icon' : 'huggingface.co/…/model-00003.safetensors'}</span>
              </span>
              <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 22, height: 22, borderRadius: 6, background: c.green }}>
                <Icon d={P.download} size={13} sw={2} color={c.onAccent} />
              </span>
            </button>
          </div>

          {/* ── in transit ── */}
          <ManifestHead no={String(live.length).padStart(2, '0')}>In transit</ManifestHead>
          {live.length ? <div>{live.map((j, i) => <ManifestActiveRow key={j.id} job={j} idx={i + 1} onToggle={toggle} comfy={comfy} />)}</div> : <EmptyLine>Nothing in transit.</EmptyLine>}
        </>
      )}

      {/* ── recorded (provenance) — reads offline, shows even when daemon down ── */}
      <div style={{ marginTop: 13 }}>
        <ManifestHead no={empty ? '0' : '48'}>Recorded</ManifestHead>
        {recent.length ? <div>{recent.map((j) => <ManifestProvRow key={j.id} job={j} comfy={comfy} />)}</div> : <EmptyLine>No downloads recorded yet.</EmptyLine>}
      </div>

      {/* trust ribbon */}
      <div style={{ margin: '12px 16px 0', padding: '9px 12px', borderRadius: 9, background: c.panel, boxShadow: `inset 0 0 0 0.5px ${c.hair2}`,
        display: 'flex', alignItems: 'center', gap: 10 }}>
        <Icon d={P.shield} size={15} sw={1.5} color={c.dim} />
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.dim, flex: 1 }}>
          {empty ? 'No downloads recorded yet' : <><span style={{ color: c.type, fontWeight: 600 }}>48</span> tracked · <span style={{ color: c.type, fontWeight: 600 }}>41</span> verified · <span style={{ color: c.type, fontWeight: 600 }}>7</span> download-only</>}
        </span>
        <span style={{ fontFamily: FONT.ui, fontSize: 11, fontWeight: 600, color: c.green, cursor: 'pointer' }}>Open →</span>
      </div>

      {/* ── footer ── */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '11px 16px 12px', marginTop: 11, borderTop: `0.5px solid ${c.hair}` }}>
        <ManifestFootLink d={P.terminal} label="Terminal" />
        <ManifestFootLink d={P.stack} label="Downloads" />
        <span style={{ flex: 1 }} />
        <ManifestFootLink d={P.quit} label="Quit" danger />
      </div>
    </Popover>
  );
}

Object.assign(window, { ManifestPopover, ManifestSpark, ManifestHead, ManifestProvRow });
