/* dirWin.jsx — Add Download + Trust + Preferences windows, theme-aware (dark + light) */
/* eslint-disable */

function TrafficLights() {
  const dot = (col) => ({ width: 11, height: 11, borderRadius: 6, background: col, boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.25)' });
  return (
    <div style={{ display: 'flex', gap: 8, position: 'absolute', left: 14, top: '50%', transform: 'translateY(-50%)' }}>
      <span style={dot('#FF5F57')} /><span style={dot('#FEBC2E')} /><span style={dot('#28C840')} />
    </div>
  );
}

function MacWindow({ width, title, children, titleMark }) {
  const c = useTheme();
  return (
    <div style={{
      width, borderRadius: 12, overflow: 'hidden', fontFamily: FONT.ui, color: c.type,
      background: c.winBg,
      backdropFilter: 'blur(50px) saturate(170%)', WebkitBackdropFilter: 'blur(50px) saturate(170%)',
      boxShadow: `inset 0 0 0 0.5px ${c.hair}, ${c.winShadow}`,
    }}>
      <div style={{ height: 42, position: 'relative', display: 'flex', alignItems: 'center', justifyContent: 'center',
        borderBottom: `0.5px solid ${c.hair}`, background: c.titleBar }}>
        <TrafficLights />
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8, fontSize: 12.5, fontWeight: 600, color: c.dim, letterSpacing: '-0.005em' }}>
          {titleMark && <><WordmarkGoh h={15} type={c.type} accent={c.wordmarkArrow} /><span style={{ width: 0.5, height: 13, background: c.hair, margin: '0 2px' }} /></>}
          {title}
        </span>
      </div>
      {children}
    </div>
  );
}

function Field({ label, children }) {
  const c = useTheme();
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
      <span style={{ fontFamily: FONT.mono, fontSize: 9.5, fontWeight: 600, letterSpacing: '0.13em', color: c.faint, textTransform: 'uppercase' }}>{label}</span>
      {children}
    </div>
  );
}

function Toggle({ on, onClick }) {
  const c = useTheme();
  return (
    <button className="goh-btn" onClick={onClick} style={{ width: 38, height: 22, borderRadius: 11, border: 'none', cursor: 'pointer', padding: 0,
      background: on ? c.green : c.toggleOff, position: 'relative', flexShrink: 0, transition: 'background .15s' }}>
      <span style={{ position: 'absolute', top: 2, left: on ? 18 : 2, width: 18, height: 18, borderRadius: 9, background: c.knob,
        boxShadow: '0 1px 3px rgba(0,0,0,0.35)', transition: 'left .16s cubic-bezier(.4,0,.2,1)' }} />
    </button>
  );
}

function WinPill({ children, onClick }) {
  const c = useTheme();
  return (
    <button className="goh-btn" onClick={onClick}
      style={{ padding: '8px 13px', borderRadius: 8, border: `0.5px solid ${c.hair}`, background: c.fill, color: c.type, fontSize: 12, fontWeight: 500, cursor: 'pointer' }}>{children}</button>
  );
}

function GreenButton({ children, big }) {
  const c = useTheme();
  return (
    <button className="goh-btn" style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: big ? '8px 18px' : '8px 16px', borderRadius: 8, border: 'none',
      background: c.green, color: c.onAccent, fontSize: big ? 12.5 : 12, fontWeight: 700, cursor: 'pointer', boxShadow: c.glow ? `0 0 18px ${c.greenDim}` : 'none' }}>{children}</button>
  );
}

function AddDownloadWindow() {
  const c = useTheme();
  const [auto, setAuto] = useState(true);
  const [conns, setConns] = useState(8);
  const stepBtn = (label, fn, disabled) => (
    <button className="goh-btn" onClick={fn} disabled={disabled} style={{ width: 26, height: 26, borderRadius: 6, border: 'none', cursor: disabled ? 'default' : 'pointer',
      background: c.fillBtn, color: disabled ? c.faint : c.type, fontSize: 15, display: 'flex', alignItems: 'center', justifyContent: 'center', opacity: disabled ? 0.5 : 1 }}>{label}</button>
  );
  return (
    <MacWindow width={468} title="Add Download" titleMark>
      <div style={{ padding: '20px 22px 18px', display: 'flex', flexDirection: 'column', gap: 17 }}>
        <Field label="URL">
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '9px 11px', borderRadius: 8, background: c.inset, boxShadow: `inset 0 0 0 1px ${c.greenDim}` }}>
            <Icon d={P.link} size={14} color={c.green} />
            <span style={{ fontFamily: FONT.mono, fontSize: 12, color: c.type, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
              https://huggingface.co/meta-llama/…/model-00003.safetensors
            </span>
          </div>
        </Field>

        <Field label="Destination">
          <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '8px 11px', borderRadius: 8, background: c.fill, flex: 1, minWidth: 0 }}>
              <Icon d={P.folder} size={14} color={c.dim} />
              <span style={{ fontFamily: FONT.mono, fontSize: 11.5, color: c.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>~/Downloads</span>
              <span style={{ fontFamily: FONT.ui, fontSize: 10, color: c.faint, marginLeft: 'auto', flexShrink: 0 }}>default</span>
            </span>
            <WinPill>Choose…</WinPill>
          </div>
        </Field>

        <Field label="Connections">
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <Toggle on={auto} onClick={() => setAuto((v) => !v)} />
            <span style={{ fontSize: 12.5, fontWeight: 500, color: c.type }}>Automatic</span>
            {auto ? (
              <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.faint, marginLeft: 2 }}>ε-greedy · learns the best count per host</span>
            ) : (
              <span style={{ display: 'flex', alignItems: 'center', gap: 8, marginLeft: 'auto' }}>
                {stepBtn('−', () => setConns((x) => Math.max(1, x - 1)))}
                <span style={{ fontFamily: FONT.mono, fontSize: 14, fontWeight: 600, width: 22, textAlign: 'center', color: c.type }}>{conns}</span>
                {stepBtn('+', () => setConns((x) => Math.min(16, x + 1)))}
              </span>
            )}
          </div>
        </Field>

        <div style={{ display: 'flex', alignItems: 'center', gap: 7, padding: '9px 11px', borderRadius: 8, background: c.ctaTint, boxShadow: `inset 0 0 0 0.5px ${c.hair2}` }}>
          <Icon d={P.shield} size={13} sw={1.5} color={c.green} />
          <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.dim }}>SHA-256 hashed in-flight · recorded to your ledger on completion</span>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 10, padding: '13px 22px', borderTop: `0.5px solid ${c.hair}`, background: c.footer }}>
        <WinPill>Cancel</WinPill>
        <GreenButton big><Icon d={P.download} size={14} sw={2.2} color={c.onAccent} /> Add</GreenButton>
      </div>
    </MacWindow>
  );
}

// ── Trust window ───────────────────────────────────────────────────────────
const LEDGER = [
  { name: 'llama-3.1-70b-instruct.safetensors', host: 'huggingface.co', sha: 'a1f3c8…9c20', dl: 'Jun 5', vr: 'Jun 7', size: '68.4 GB' },
  { name: 'sd-xl-base-1.0.safetensors', host: 'huggingface.co', sha: '77be02…01da', dl: 'Jun 4', vr: 'Jun 7', size: '6.94 GB' },
  { name: 'imagenet-val.tar.zst', host: 'image-net.org', sha: '3d9a11…ee47', dl: 'Jun 2', vr: 'Jun 6', size: '6.40 GB' },
  { name: 'config.json', host: 'huggingface.co', sha: '5c1f0a…77b2', dl: 'Jun 5', vr: 'Jun 5', size: '4.2 KB' },
  { name: 'tokenizer.model', host: 'huggingface.co', sha: 'b820ee…1a4c', dl: 'Jun 1', vr: null, size: '2.1 MB' },
  { name: 'vocab.bpe', host: 'cdn.example.com', sha: '00aa55…9f31', dl: 'May 30', vr: 'CHANGED', size: '1.0 MB' },
  { name: 'dataset-card.md', host: 'huggingface.co', sha: '9911ab…34de', dl: 'May 28', vr: 'May 28', size: '12 KB' },
];

function TrustStat({ value, label, color }) {
  const c = useTheme();
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <span style={{ fontFamily: FONT.mono, fontSize: 26, fontWeight: 600, color: color || c.type, letterSpacing: '-0.02em', lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{value}</span>
      <span style={{ fontFamily: FONT.mono, fontSize: 9, letterSpacing: '0.12em', color: c.faint, fontWeight: 600, textTransform: 'uppercase' }}>{label}</span>
    </div>
  );
}

function TrustRow({ e, i, selected, onClick }) {
  const c = useTheme();
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(e.name);
  const changed = e.vr === 'CHANGED';
  const dlOnly = e.vr === null;
  return (
    <div onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)} onClick={onClick}
      style={{ display: 'grid', gridTemplateColumns: '1.7fr 1.1fr 1fr 0.7fr 0.8fr', alignItems: 'center', gap: 12, padding: '10px 18px', cursor: 'pointer',
        background: selected ? c.selRow : (h ? c.rowHover : 'transparent'),
        boxShadow: selected ? `inset 2px 0 0 ${c.green}` : 'none', borderTop: i ? `0.5px solid ${c.hair2}` : 'none' }}>
      <span style={{ fontSize: 12.5, fontWeight: 500, color: c.type, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {stem}<span style={{ fontFamily: FONT.mono, color: c.dim, fontWeight: 400 }}>{ext}</span>
      </span>
      <span style={{ fontFamily: FONT.mono, fontSize: 10.5, color: c.dim, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{e.host}</span>
      <span style={{ fontFamily: FONT.mono, fontSize: 10.5, color: c.sha, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>sha256:{e.sha}</span>
      <span style={{ fontFamily: FONT.mono, fontSize: 10.5, color: c.faint }}>{e.dl}</span>
      <span>
        {changed ? (
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: FONT.mono, fontSize: 10, color: c.oxblood, fontWeight: 600 }}>
            <Icon d={P.x} size={11} sw={2.4} color={c.oxblood} /> changed
          </span>
        ) : dlOnly ? (
          <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.faint }}>download-only</span>
        ) : (
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: FONT.mono, fontSize: 10, color: c.dim, fontWeight: 500 }}>
            <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 13, height: 13, borderRadius: 7, boxShadow: `inset 0 0 0 1px ${c.dim}` }}><Icon d={P.check} size={8} sw={2.6} color={c.type} /></span>
            {e.vr}
          </span>
        )}
      </span>
    </div>
  );
}

function TrustWindow() {
  const c = useTheme();
  const [sel, setSel] = useState(0);
  const cols = ['File', 'Source', 'SHA-256', 'Pulled', 'Verified'];
  return (
    <MacWindow width={720} title="Trust — Provenance Ledger" titleMark>
      <div style={{ display: 'flex', alignItems: 'center', gap: 30, padding: '18px 22px 16px' }}>
        <TrustStat value="48" label="tracked" />
        <span style={{ width: 0.5, height: 34, background: c.hair }} />
        <TrustStat value="41" label="verified" color={c.green} />
        <TrustStat value="7" label="download-only" />
        <TrustStat value="1" label="changed" color={c.oxblood} />
        <span style={{ flex: 1 }} />
        <span style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 11px', borderRadius: 8, background: c.inset, boxShadow: `inset 0 0 0 0.5px ${c.hair}`, width: 180 }}>
          <Icon d={P.search} size={13} color={c.faint} />
          <span style={{ fontFamily: FONT.mono, fontSize: 11, color: c.faint }}>filter…</span>
        </span>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1.7fr 1.1fr 1fr 0.7fr 0.8fr', gap: 12, padding: '8px 18px', borderTop: `0.5px solid ${c.hair}`, borderBottom: `0.5px solid ${c.hair}`, background: c.footer }}>
        {cols.map((col) => <span key={col} style={{ fontFamily: FONT.mono, fontSize: 9, fontWeight: 600, letterSpacing: '0.12em', color: c.faint, textTransform: 'uppercase' }}>{col}</span>)}
      </div>

      <div>{LEDGER.map((e, i) => <TrustRow key={e.name} e={e} i={i} selected={sel === i} onClick={() => setSel(i)} />)}</div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 22px', borderTop: `0.5px solid ${c.hair}`, background: c.footer }}>
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.faint }}>$ goh verify --all</span>
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.dim }}>→ 47 ok · 1 changed · exit 2</span>
        <span style={{ flex: 1 }} />
        <button className="goh-btn" style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '8px 14px', borderRadius: 8, border: `0.5px solid ${c.hair}`, background: c.fill, color: c.type, fontSize: 12, fontWeight: 500, cursor: 'pointer' }}>
          <Icon d={P.bolt} size={13} sw={1.8} color={c.dim} /> Attest…
        </button>
        <GreenButton><Icon d={P.shield} size={13} sw={2} color={c.onAccent} /> Verify all</GreenButton>
      </div>
    </MacWindow>
  );
}

// ── Preferences window ─────────────────────────────────────────────────────
function PrefRow({ title, desc, children, last }) {
  const c = useTheme();
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '13px 0', borderBottom: last ? 'none' : `0.5px solid ${c.hair2}` }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12.5, fontWeight: 500, color: c.type }}>{title}</div>
        {desc && <div style={{ fontSize: 11, color: c.faint, marginTop: 2, lineHeight: 1.35 }}>{desc}</div>}
      </div>
      <div style={{ flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8 }}>{children}</div>
    </div>
  );
}

function PrefStepper({ value, onChange, min = 1, max = 16, disabled }) {
  const c = useTheme();
  const b = (label, fn) => (
    <button className="goh-btn" onClick={disabled ? undefined : fn} disabled={disabled}
      style={{ width: 24, height: 24, borderRadius: 6, border: 'none', cursor: disabled ? 'default' : 'pointer', background: c.fillBtn, color: disabled ? c.faint : c.type, fontSize: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', opacity: disabled ? 0.4 : 1 }}>{label}</button>
  );
  return (
    <span style={{ display: 'flex', alignItems: 'center', gap: 7, opacity: disabled ? 0.5 : 1 }}>
      {b('−', () => onChange(Math.max(min, value - 1)))}
      <span style={{ fontFamily: FONT.mono, fontSize: 13, fontWeight: 600, width: 20, textAlign: 'center', color: c.type }}>{value}</span>
      {b('+', () => onChange(Math.min(max, value + 1)))}
    </span>
  );
}

function PrefPillBtn({ children, onClick }) {
  const c = useTheme();
  return (
    <button className="goh-btn" onClick={onClick}
      style={{ padding: '6px 12px', borderRadius: 7, border: `0.5px solid ${c.hair}`, background: c.fill, color: c.type, fontSize: 11.5, fontWeight: 500, cursor: 'pointer' }}>{children}</button>
  );
}

function PreferencesWindow() {
  const c = useTheme();
  const [tab, setTab] = useState('general');
  const [s, setS] = useState({ login: true, menubar: true, arrowProgress: true, notifyDone: true, notifyFail: true, cellular: true, keepPartial: false, autoConn: true, conns: 8, ceiling: 16, verifyLaunch: false, trace: false });
  const set = (k, v) => setS((o) => ({ ...o, [k]: v }));
  const TABS = [['general', 'General', P.gear], ['downloads', 'Downloads', P.stack], ['trust', 'Trust', P.shield], ['advanced', 'Advanced', P.bolt]];

  return (
    <MacWindow width={524} title="Preferences" titleMark>
      <div style={{ display: 'flex', gap: 4, padding: '9px 12px', borderBottom: `0.5px solid ${c.hair}`, background: c.titleBar }}>
        {TABS.map(([id, label, icon]) => {
          const on = tab === id;
          return (
            <button key={id} className="goh-btn" onClick={() => setTab(id)}
              style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, width: 72, padding: '7px 0', borderRadius: 8, border: 'none', cursor: 'pointer',
                background: on ? c.fillH : 'transparent', color: on ? c.type : c.dim }}>
              <Icon d={icon} size={17} sw={1.6} color={on ? c.green : 'currentColor'} />
              <span style={{ fontSize: 11, fontWeight: on ? 600 : 500 }}>{label}</span>
            </button>
          );
        })}
      </div>

      <div style={{ padding: '4px 22px 16px', minHeight: 232 }}>
        {tab === 'general' && (
          <>
            <PrefRow title="Launch at login" desc="Start the goh companion when you log in."><Toggle on={s.login} onClick={() => set('login', !s.login)} /></PrefRow>
            <PrefRow title="Show in menu bar" desc="Keep the goh status item visible."><Toggle on={s.menubar} onClick={() => set('menubar', !s.menubar)} /></PrefRow>
            <PrefRow title="Progress on the icon" desc="Brighten the arrow as a download nears completion."><Toggle on={s.arrowProgress} onClick={() => set('arrowProgress', !s.arrowProgress)} /></PrefRow>
            <PrefRow title="Notify on completion"><Toggle on={s.notifyDone} onClick={() => set('notifyDone', !s.notifyDone)} /></PrefRow>
            <PrefRow title="Notify on failure" last><Toggle on={s.notifyFail} onClick={() => set('notifyFail', !s.notifyFail)} /></PrefRow>
          </>
        )}
        {tab === 'downloads' && (
          <>
            <PrefRow title="Default destination" desc="Where new downloads are saved.">
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '6px 10px', borderRadius: 7, background: c.fill }}>
                <Icon d={P.folder} size={13} color={c.dim} /><span style={{ fontFamily: FONT.mono, fontSize: 11, color: c.dim }}>~/Downloads</span>
              </span>
              <PrefPillBtn>Choose…</PrefPillBtn>
            </PrefRow>
            <PrefRow title="Connections" desc={s.autoConn ? 'Automatic — ε-greedy, learns the best count per host.' : 'Fixed connection count per download.'}>
              <Toggle on={s.autoConn} onClick={() => set('autoConn', !s.autoConn)} />
              <PrefStepper value={s.conns} onChange={(v) => set('conns', v)} disabled={s.autoConn} />
            </PrefRow>
            <PrefRow title="Pause on cellular" desc="Auto-pause transfers on metered networks."><Toggle on={s.cellular} onClick={() => set('cellular', !s.cellular)} /></PrefRow>
            <PrefRow title="Keep partial files on remove" last><Toggle on={s.keepPartial} onClick={() => set('keepPartial', !s.keepPartial)} /></PrefRow>
          </>
        )}
        {tab === 'trust' && (
          <>
            <PrefRow title="Record provenance" desc="Every download is hashed and logged to your ledger. Always on.">
              <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.green, fontWeight: 600, display: 'inline-flex', alignItems: 'center', gap: 5 }}>
                <span style={{ width: 5, height: 5, borderRadius: 3, background: c.green, boxShadow: c.glow ? `0 0 6px ${c.green}` : 'none' }} />LOCKED ON
              </span>
            </PrefRow>
            <PrefRow title="Verify ledger on launch" desc="Re-hash recorded files when the app starts."><Toggle on={s.verifyLaunch} onClick={() => set('verifyLaunch', !s.verifyLaunch)} /></PrefRow>
            <PrefRow title="Attestation key" desc="Secure Enclave P-256 · the private key never leaves this Mac." last>
              <span style={{ fontFamily: FONT.mono, fontSize: 10.5, color: c.dim }}>kid 3f8a1c20</span>
              <PrefPillBtn>Regenerate…</PrefPillBtn>
            </PrefRow>
          </>
        )}
        {tab === 'advanced' && (
          <>
            <PrefRow title="Authenticated downloads" desc="Import cookies from Safari for gated files.">
              <PrefPillBtn>Import from Safari…</PrefPillBtn>
            </PrefRow>
            <PrefRow title="Connection ceiling" desc="Hard cap on parallel connections per host.">
              <PrefStepper value={s.ceiling} onChange={(v) => set('ceiling', v)} min={2} max={16} />
            </PrefRow>
            <PrefRow title="Reset host scheduling" desc="Clear the learned per-host connection profiles.">
              <PrefPillBtn>Reset…</PrefPillBtn>
            </PrefRow>
            <PrefRow title="Engine trace logging" desc="GOH_ENGINE_TRACE — verbose scheduler diagnostics." last><Toggle on={s.trace} onClick={() => set('trace', !s.trace)} /></PrefRow>
          </>
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 22px', borderTop: `0.5px solid ${c.hair}`, background: c.footer }}>
        <span style={{ fontFamily: FONT.mono, fontSize: 10, color: c.faint }}>goh v0.1 · macOS 26.0+ · Apple Silicon</span>
        <span style={{ flex: 1 }} />
        <PrefPillBtn>Open docs</PrefPillBtn>
      </div>
    </MacWindow>
  );
}

Object.assign(window, { AddDownloadWindow, TrustWindow, PreferencesWindow, MacWindow });
