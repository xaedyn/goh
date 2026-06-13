/* appleWin.jsx — Add Download / Trust / Preferences in Apple HIG, both themes.
   SF only, monospaced digits, grouped inset rows, systemRed/Green, neutral light chrome. */
/* eslint-disable */

function winTokens(dark) {
  const t = appleTokens(dark);
  return {
    ...t,
    // macOS 26 "Liquid Glass": windows are translucent vibrant material, like the popover
    winBg: dark
      ? 'linear-gradient(180deg, rgba(48,52,64,0.5), rgba(24,27,35,0.56))'
      : 'linear-gradient(180deg, rgba(252,252,254,0.58), rgba(243,244,248,0.62))',
    bar: dark ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.32)',
    card: dark ? 'rgba(255,255,255,0.07)' : 'rgba(255,255,255,0.55)',
    cardShadow: dark
      ? 'inset 0 1px 0 rgba(255,255,255,0.06), 0 2px 8px rgba(0,0,0,0.22)'
      : 'inset 0 0 0 0.5px rgba(0,0,0,0.05), inset 0 1px 0 rgba(255,255,255,0.9), 0 2px 8px rgba(0,0,0,0.07)',
    field: dark ? 'rgba(0,0,0,0.22)' : 'rgba(255,255,255,0.7)',
    fieldRing: dark ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.12)',
    winShadow: dark ? '0 30px 90px rgba(0,0,0,0.55)' : '0 30px 90px rgba(40,45,60,0.26)',
    blue: dark ? '#0A84FF' : '#007AFF',
    onAccent: '#FFFFFF',
  };
}

function Lights() {
  const dot = (col) => ({ width: 12, height: 12, borderRadius: 6, background: col });
  return (
    <div style={{ display: 'flex', gap: 8, position: 'absolute', left: 13, top: '50%', transform: 'translateY(-50%)' }}>
      <span style={dot('#FF5F57')} /><span style={dot('#FEBC2E')} /><span style={dot('#28C840')} />
    </div>
  );
}

function AWindow({ width, title, c, children, toolbar }) {
  return (
    <div style={{ width, borderRadius: 18, overflow: 'hidden', fontFamily: SF, color: c.label, background: c.winBg,
      backdropFilter: 'blur(72px) saturate(190%)', WebkitBackdropFilter: 'blur(72px) saturate(190%)',
      boxShadow: `inset 0 0 0 0.5px ${c.hair}, inset 0 1px 0 ${c.dark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.9)'}, ${c.winShadow}` }}>
      {/* unified glass title bar — no hard divider */}
      <div style={{ position: 'relative', display: 'flex', flexDirection: 'column' }}>
        <div style={{ height: 46, position: 'relative', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Lights />
          <span style={{ fontSize: 13, fontWeight: 600, color: c.label, letterSpacing: '-0.01em' }}>{title}</span>
        </div>
        {toolbar}
      </div>
      {children}
    </div>
  );
}

// grouped form row
function Row({ c, label, sub, children, last }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '10px 14px', minHeight: 44, borderTop: last === 'first' ? 'none' : `0.5px solid ${c.sep}` }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, color: c.label, fontWeight: 400 }}>{label}</div>
        {sub && <div style={{ fontSize: 11, color: c.sec, marginTop: 2, lineHeight: 1.3 }}>{sub}</div>}
      </div>
      <div style={{ flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8 }}>{children}</div>
    </div>
  );
}

function Group({ c, children, label }) {
  return (
    <div style={{ marginBottom: 16 }}>
      {label && <div style={{ fontSize: 11, fontWeight: 600, color: c.sec, textTransform: 'uppercase', letterSpacing: '0.04em', padding: '0 6px 6px', margin: '0 14px' }}>{label}</div>}
      <div style={{ margin: '0 14px', borderRadius: 13, background: c.card, overflow: 'hidden', boxShadow: c.cardShadow }}>{children}</div>
    </div>
  );
}

function Switch({ on, onClick, c }) {
  return (
    <button className="goh-btn" onClick={onClick} style={{ width: 38, height: 23, borderRadius: 12, border: 'none', cursor: 'pointer', padding: 0,
      background: on ? c.green : (c.dark ? 'rgba(255,255,255,0.18)' : 'rgba(0,0,0,0.16)'), position: 'relative', transition: 'background .15s' }}>
      <span style={{ position: 'absolute', top: 2, left: on ? 17 : 2, width: 19, height: 19, borderRadius: 10, background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.3)', transition: 'left .16s cubic-bezier(.4,0,.2,1)' }} />
    </button>
  );
}

function Popup({ children, c }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '5px 9px 5px 11px', borderRadius: 7, background: c.dark ? 'rgba(255,255,255,0.10)' : '#fff',
      boxShadow: c.dark ? 'inset 0 0 0 0.5px rgba(255,255,255,0.12)' : '0 0.5px 2px rgba(0,0,0,0.2), inset 0 0 0 0.5px rgba(0,0,0,0.06)', fontSize: 12.5, color: c.label, cursor: 'pointer' }}>
      {children}
      <svg width="11" height="11" viewBox="0 0 12 12" style={{ marginLeft: 2 }}><path d="M3.5 5L6 7.2 8.5 5" fill="none" stroke={c.sec} strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" transform="translate(0 -1)" /><path d="M3.5 7L6 4.8 8.5 7" fill="none" stroke={c.sec} strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" transform="translate(0 1)" /></svg>
    </span>
  );
}

function Stepper({ value, onChange, min = 1, max = 16, c, disabled }) {
  const b = (label, fn) => (
    <button className="goh-btn" disabled={disabled} onClick={disabled ? undefined : fn}
      style={{ width: 26, height: 24, border: 'none', cursor: disabled ? 'default' : 'pointer', background: c.dark ? 'rgba(255,255,255,0.10)' : '#fff', color: disabled ? c.ter : c.label, fontSize: 15, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: c.dark ? 'none' : 'inset 0 0 0 0.5px rgba(0,0,0,0.08)' }}>{label}</button>
  );
  return (
    <span style={{ display: 'flex', alignItems: 'center', gap: 10, opacity: disabled ? 0.45 : 1 }}>
      <span style={{ fontSize: 13, color: c.label, width: 14, textAlign: 'right', ...NUM }}>{value}</span>
      <span style={{ display: 'inline-flex', borderRadius: 6, overflow: 'hidden', boxShadow: c.dark ? 'inset 0 0 0 0.5px rgba(255,255,255,0.12)' : '0 0.5px 1.5px rgba(0,0,0,0.2)' }}>
        {b('−', () => onChange(Math.max(min, value - 1)))}
        <span style={{ width: 0.5, background: c.sep }} />
        {b('+', () => onChange(Math.min(max, value + 1)))}
      </span>
    </span>
  );
}

function PushBtn({ children, c, accent, onClick }) {
  return (
    <button className="goh-btn" onClick={onClick} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 15px', borderRadius: 7, border: 'none', cursor: 'pointer',
      fontFamily: SF, fontSize: 13, fontWeight: accent ? 600 : 500,
      background: accent ? c.green : (c.dark ? 'rgba(255,255,255,0.13)' : '#fff'),
      color: accent ? c.onAccent : c.label,
      boxShadow: accent ? 'none' : (c.dark ? 'inset 0 0 0 0.5px rgba(255,255,255,0.14)' : '0 0.5px 2px rgba(0,0,0,0.18), inset 0 0 0 0.5px rgba(0,0,0,0.04)') }}>{children}</button>
  );
}

// ── Add Download ───────────────────────────────────────────────────────────
function AppleAddWindow({ mode = 'dark' }) {
  const c = winTokens(mode === 'dark');
  const [auto, setAuto] = useState(true);
  const [conns, setConns] = useState(8);
  return (
    <AWindow width={420} title="Add Download" c={c}>
      <div style={{ padding: '16px 0 0' }}>
        <Group c={c}>
          <div style={{ padding: '11px 14px' }}>
            <div style={{ fontSize: 11, fontWeight: 600, color: c.sec, marginBottom: 7 }}>URL</div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 10px', borderRadius: 7, background: c.field, boxShadow: `0 0 0 3px ${c.green}2e, inset 0 0 0 1px ${c.green}` }}>
              <Icon d={P.link} size={14} color={c.sec} />
              <span style={{ fontSize: 12.5, color: c.label, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>https://huggingface.co/…/model-00003.safetensors</span>
            </div>
          </div>
        </Group>

        <Group c={c}>
          <Row c={c} label="Save to" last="first"><Popup c={c}><Icon d={P.folder} size={13} color={c.sec} /> Downloads</Popup></Row>
          <Row c={c} label="Connections" sub={auto ? 'Automatic — learns the best count per host' : 'Fixed number of parallel connections'}>
            <Switch on={auto} onClick={() => setAuto((v) => !v)} c={c} />
          </Row>
          {!auto && <Row c={c} label="Parallel connections"><Stepper value={conns} onChange={setConns} c={c} /></Row>}
        </Group>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '0 20px 4px' }}>
          <Icon d="M12 2a10 10 0 100 20 10 10 0 000-20z M8.5 12l2.5 2.5 4.5-5" size={14} sw={1.6} color={c.green} />
          <span style={{ fontSize: 11.5, color: c.sec }}>Hashed in-flight and recorded to your ledger on completion.</span>
        </div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, padding: '14px 16px 16px' }}>
        <PushBtn c={c}>Cancel</PushBtn>
        <PushBtn c={c} accent><Icon d={P.download} size={14} sw={2} color={c.onAccent} /> Add</PushBtn>
      </div>
    </AWindow>
  );
}

// ── Trust ──────────────────────────────────────────────────────────────────
const TRUST = [
  { name: 'llama-3.1-70b-instruct.safetensors', host: 'huggingface.co', url: 'huggingface.co/meta-llama/Llama-3.1-70B-Instruct/resolve/main/model-00003.safetensors', size: '68.4 GB', dl: 'Jun 5, 2026 · 9:32 AM', vr: 'Jun 7, 2026 · 8:14 AM', status: 'verified', sha: 'a1f3c8e24b7d0f9133ac77be0291da5c1f0a77b2b820ee1a4c3d9a11ee479c20' },
  { name: 'sd-xl-base-1.0.safetensors', host: 'huggingface.co', url: 'huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors', size: '6.94 GB', dl: 'Jun 4, 2026 · 3:11 PM', vr: 'Jun 7, 2026 · 8:14 AM', status: 'verified', sha: '77be0201da55903d9a11ee4700aa559f31b1c2774aee470c205c1f0a77b2b820' },
  { name: 'imagenet-val.tar.zst', host: 'image-net.org', url: 'image-net.org/data/ILSVRC/2012/ILSVRC2012_img_val.tar.zst', size: '6.40 GB', dl: 'Jun 2, 2026 · 11:02 AM', vr: 'Jun 6, 2026 · 7:40 PM', status: 'verified', sha: '3d9a11ee4700aa559f31b1c2774aee470c205c1f0a77b2b82077be0201da5590' },
  { name: 'tokenizer.model', host: 'huggingface.co', url: 'huggingface.co/meta-llama/Llama-3.1-70B-Instruct/resolve/main/tokenizer.model', size: '2.1 MB', dl: 'Jun 1, 2026 · 6:20 PM', vr: null, status: 'download-only', sha: 'b820ee1a4c3d9a11ee479c2077be0201da55903d9a11ee4700aa559f31b1c277' },
  { name: 'vocab.bpe', host: 'cdn.example.com', url: 'cdn.example.com/gpt2/vocab.bpe', size: '1.0 MB', dl: 'May 30, 2026 · 2:45 PM', vr: 'Jun 8, 2026 · 9:38 AM', status: 'changed', sha: '00aa559f31b1c2774aee470c205c1f0a77b2b82077be0201da55903d9a11ee47', currentSha: '00aa559f31b1c2774a4f8e9302be01779c20a1f3c8e24b7d0f9133ac77be0291' },
];

const STATUS_SYM = {
  verified: 'M12 2a10 10 0 100 20 10 10 0 000-20z M8.5 12l2.5 2.5 4.5-5',
  'download-only': 'M12 4v10 M8 11l4 3 4-3 M6 19h12',
  changed: 'M12 2a10 10 0 100 20 10 10 0 000-20z M12 7v6 M12 16.3v.2',
};
const STATUS_LABEL = { verified: 'Verified', 'download-only': 'Download-only', changed: 'Changed' };
const statusColor = (c, s) => s === 'changed' ? c.red : s === 'download-only' ? c.sec : c.green;

// 64-hex hash, grouped in 8s; chars that differ from `compare` are highlighted.
function HashBlock({ hash, compare, c, color }) {
  return (
    <div style={{ fontFamily: '"JetBrains Mono", ui-monospace, monospace', fontSize: 11, lineHeight: 1.85, letterSpacing: '0.03em', wordBreak: 'break-all' }}>
      {hash.split('').map((ch, i) => {
        const diff = compare && ch !== compare[i];
        return <span key={i} style={{ color: diff ? c.red : (color || c.label), fontWeight: diff ? 700 : 400, background: diff ? (c.dark ? 'rgba(255,69,58,0.22)' : 'rgba(255,59,48,0.14)') : 'transparent', borderRadius: diff ? 2 : 0 }}>{ch}{(i + 1) % 8 === 0 ? '\u2009' : ''}</span>;
      })}
    </div>
  );
}

function InspSection({ label, c, children }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ fontSize: 10.5, fontWeight: 600, color: c.sec, textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 7 }}>{label}</div>
      {children}
    </div>
  );
}
function InspRow({ k, v, c, mono }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, padding: '4px 0' }}>
      <span style={{ fontSize: 12, color: c.sec, width: 96, flexShrink: 0 }}>{k}</span>
      <span style={{ fontSize: 12, color: c.label, flex: 1, minWidth: 0, wordBreak: 'break-all', fontFamily: mono ? '"JetBrains Mono", monospace' : SF, ...(mono ? NUM : {}) }}>{v}</span>
    </div>
  );
}

function TrustInspector({ e, c }) {
  const col = statusColor(c, e.status);
  const changed = e.status === 'changed';
  const dlOnly = e.status === 'download-only';
  return (
    <div style={{ padding: '16px 18px' }}>
      {/* header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 16 }}>
        <span style={{ width: 40, height: 40, borderRadius: 10, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: changed ? (c.dark ? 'rgba(255,69,58,0.15)' : 'rgba(255,59,48,0.1)') : 'rgba(52,210,102,0.14)' }}>
          <Icon d={STATUS_SYM[e.status]} size={22} sw={1.7} color={col} />
        </span>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: c.label, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{e.name}</div>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, marginTop: 4, fontSize: 11, fontWeight: 600, color: col, background: changed ? (c.dark ? 'rgba(255,69,58,0.14)' : 'rgba(255,59,48,0.1)') : (c.dark ? 'rgba(52,210,102,0.14)' : 'rgba(40,168,90,0.12)'), padding: '2px 8px', borderRadius: 6 }}>{STATUS_LABEL[e.status]}</span>
        </div>
      </div>

      {changed && (
        <div style={{ display: 'flex', gap: 9, padding: '11px 12px', borderRadius: 10, marginBottom: 16, background: c.dark ? 'rgba(255,69,58,0.12)' : 'rgba(255,59,48,0.08)', boxShadow: `inset 0 0 0 0.5px ${c.dark ? 'rgba(255,69,58,0.3)' : 'rgba(255,59,48,0.22)'}` }}>
          <Icon d="M12 3.2L2.6 19a1 1 0 00.87 1.5h17.06A1 1 0 0021.4 19L12 3.2z M12 10v4 M11.9 17.1h.2" size={16} sw={1.6} color={c.red} />
          <div>
            <div style={{ fontSize: 12.5, fontWeight: 600, color: c.label }}>This file changed since it was recorded</div>
            <div style={{ fontSize: 11.5, color: c.sec, marginTop: 2, lineHeight: 1.35 }}>The on-disk contents no longer match the recorded signature. Provenance is broken until you re-download or update the record.</div>
          </div>
        </div>
      )}

      <InspSection label="Source" c={c}>
        <InspRow k="URL" v={e.url} c={c} mono />
        <InspRow k="Size" v={e.size} c={c} />
        <InspRow k="Downloaded" v={e.dl} c={c} />
        <InspRow k="Last checked" v={e.vr || 'Never'} c={c} />
      </InspSection>

      <InspSection label={changed ? 'Integrity — SHA-256 mismatch' : 'Integrity — SHA-256'} c={c}>
        {changed ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div>
              <div style={{ fontSize: 11, color: c.sec, marginBottom: 3 }}>Recorded</div>
              <HashBlock hash={e.sha} c={c} color={c.sec} />
            </div>
            <div>
              <div style={{ fontSize: 11, color: c.red, fontWeight: 600, marginBottom: 3 }}>Current (on disk)</div>
              <HashBlock hash={e.currentSha} compare={e.sha} c={c} />
            </div>
          </div>
        ) : (
          <>
            <HashBlock hash={e.sha} c={c} />
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, marginTop: 8, fontSize: 11.5, color: dlOnly ? c.sec : c.green }}>
              {dlOnly
                ? <>Not yet checked against a recorded signature.</>
                : <><Icon d="M12 2a10 10 0 100 20 10 10 0 000-20z M8.5 12l2.5 2.5 4.5-5" size={13} sw={1.7} color={c.green} /> Matches the recorded signature.</>}
            </div>
          </>
        )}
      </InspSection>

      <InspSection label="Attestation" c={c}>
        {changed
          ? <div style={{ fontSize: 12, color: c.sec, lineHeight: 1.4 }}>The recorded signature <span style={{ fontFamily: '"JetBrains Mono", monospace', color: c.label }}>kid 3f8a1c20</span> no longer applies to this file.</div>
          : dlOnly
            ? <div style={{ fontSize: 12, color: c.sec, lineHeight: 1.4 }}>No local attestation yet — verify to sign with the Secure Enclave key.</div>
            : <div style={{ fontSize: 12, color: c.sec, lineHeight: 1.4 }}>Signed locally · Secure Enclave P-256 · <span style={{ fontFamily: '"JetBrains Mono", monospace', color: c.label }}>kid 3f8a1c20</span></div>}
      </InspSection>

      <InspSection label="History" c={c}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 0 }}>
          {[['Downloaded', e.dl, c.sec], ...(e.vr ? [[changed ? 'Drift detected' : 'Verified', e.vr, changed ? c.red : c.green]] : [])].map(([k, v, dotc], i, arr) => (
            <div key={k} style={{ display: 'flex', gap: 10, alignItems: 'flex-start' }}>
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', alignSelf: 'stretch' }}>
                <span style={{ width: 7, height: 7, borderRadius: 4, background: dotc, marginTop: 4, flexShrink: 0 }} />
                {i < arr.length - 1 && <span style={{ width: 1.5, flex: 1, background: c.sep, minHeight: 14 }} />}
              </div>
              <div style={{ paddingBottom: i < arr.length - 1 ? 10 : 0 }}>
                <div style={{ fontSize: 12, color: c.label, fontWeight: 500 }}>{k}</div>
                <div style={{ fontSize: 11, color: c.sec, ...NUM }}>{v}</div>
              </div>
            </div>
          ))}
        </div>
      </InspSection>

      {/* contextual actions */}
      <div style={{ display: 'flex', gap: 8, marginTop: 4 }}>
        {changed ? (
          <><PushBtn c={c} accent><Icon d={P.download} size={13} sw={2} color={c.onAccent} /> Re-download</PushBtn><PushBtn c={c}>Update Record</PushBtn><PushBtn c={c}>Reveal</PushBtn></>
        ) : dlOnly ? (
          <><PushBtn c={c} accent><Icon d={P.shield} size={13} sw={1.9} color={c.onAccent} /> Verify Now</PushBtn><PushBtn c={c}>Reveal</PushBtn></>
        ) : (
          <><PushBtn c={c}>Re-verify</PushBtn><PushBtn c={c}>Copy Hash</PushBtn><PushBtn c={c}>Reveal</PushBtn></>
        )}
      </div>
    </div>
  );
}

function AppleTrustWindow({ mode = 'dark' }) {
  const c = winTokens(mode === 'dark');
  const [sel, setSel] = useState(4); // default to the changed file to show the diff
  return (
    <AWindow width={820} title="Trust" c={c} toolbar={
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '0 14px 11px' }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, color: c.sec }}>
          <b style={{ color: c.label, ...NUM }}>48</b> tracked
          <span style={{ color: c.ter }}>·</span><b style={{ color: c.green, ...NUM }}>41</b> verified
          <span style={{ color: c.ter }}>·</span><b style={{ color: c.sec, ...NUM }}>6</b> download-only
          <span style={{ color: c.ter }}>·</span><b style={{ color: c.red, ...NUM }}>1</b> changed
        </span>
        <span style={{ flex: 1 }} />
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '4px 9px', borderRadius: 7, background: c.dark ? 'rgba(0,0,0,0.25)' : '#fff', boxShadow: `inset 0 0 0 0.5px ${c.sep}`, width: 150 }}>
          <Icon d={P.search} size={12} color={c.ter} /><span style={{ fontSize: 12, color: c.ter }}>Search</span>
        </span>
      </div>
    }>
      <div style={{ display: 'flex', height: 432, borderTop: `0.5px solid ${c.sep}` }}>
        {/* master list */}
        <div className="goh-scroll" style={{ width: 308, borderRight: `0.5px solid ${c.sep}`, flexShrink: 0 }}>
          {TRUST.map((e, i) => (
            <div key={e.name} onClick={() => setSel(i)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', cursor: 'pointer',
              background: sel === i ? (c.dark ? 'rgba(255,255,255,0.07)' : 'rgba(0,0,0,0.05)') : 'transparent', boxShadow: sel === i ? `inset 2px 0 0 ${statusColor(c, e.status)}` : 'none', borderTop: i ? `0.5px solid ${c.sep}` : 'none' }}>
              <Icon d={STATUS_SYM[e.status]} size={17} sw={1.6} color={statusColor(c, e.status)} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 12.5, color: c.label, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{e.name}</div>
                <div style={{ fontSize: 10.5, color: e.status === 'changed' ? c.red : c.sec, marginTop: 1, ...NUM }}>{STATUS_LABEL[e.status]} · {e.size}</div>
              </div>
            </div>
          ))}
        </div>
        {/* detail inspector */}
        <div className="goh-scroll" style={{ flex: 1 }}>
          <TrustInspector e={TRUST[sel]} c={c} />
        </div>
      </div>

      {/* footer */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 16px', borderTop: `0.5px solid ${c.sep}` }}>
        <span style={{ fontSize: 11.5, color: c.sec }}>Last check: 47 OK · 1 changed</span>
        <span style={{ flex: 1 }} />
        <PushBtn c={c}><Icon d={P.bolt} size={13} sw={1.7} color={c.sec} /> Attest…</PushBtn>
        <PushBtn c={c} accent><Icon d={P.shield} size={13} sw={1.9} color={c.onAccent} /> Verify All</PushBtn>
      </div>
    </AWindow>
  );
}

// ── Preferences ──────────────────────────────────────────────────────────────
function ApplePrefsWindow({ mode = 'dark' }) {
  const c = winTokens(mode === 'dark');
  const [tab, setTab] = useState('general');
  const [s, setS] = useState({ login: true, menubar: true, progress: true, notify: true, cellular: true, autoConn: true, conns: 8, verifyLaunch: false, trace: false });
  const set = (k) => setS((o) => ({ ...o, [k]: !o[k] }));
  const TABS = [['general', 'General', P.gear], ['downloads', 'Downloads', P.stack], ['trust', 'Trust', P.shield], ['advanced', 'Advanced', P.bolt]];
  return (
    <AWindow width={480} title="goh Settings" c={c} toolbar={
      <div style={{ display: 'flex', justifyContent: 'center', gap: 2, padding: '0 10px 8px' }}>
        {TABS.map(([id, label, icon]) => {
          const on = tab === id;
          return (
            <button key={id} className="goh-btn" onClick={() => setTab(id)} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, width: 68, padding: '6px 0', borderRadius: 7, border: 'none', cursor: 'pointer', background: on ? (c.dark ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)') : 'transparent', color: on ? c.label : c.sec }}>
              <Icon d={icon} size={17} sw={1.6} color={on ? c.green : c.sec} />
              <span style={{ fontSize: 11, fontWeight: on ? 600 : 400 }}>{label}</span>
            </button>
          );
        })}
      </div>
    }>
      <div style={{ padding: '16px 0 4px', minHeight: 200 }}>
        {tab === 'general' && (
          <Group c={c}>
            <Row c={c} label="Launch at login" last="first"><Switch on={s.login} onClick={() => set('login')} c={c} /></Row>
            <Row c={c} label="Show in menu bar"><Switch on={s.menubar} onClick={() => set('menubar')} c={c} /></Row>
            <Row c={c} label="Show progress on the icon" sub="Brighten the arrow as a download completes"><Switch on={s.progress} onClick={() => set('progress')} c={c} /></Row>
            <Row c={c} label="Notify when downloads finish"><Switch on={s.notify} onClick={() => set('notify')} c={c} /></Row>
          </Group>
        )}
        {tab === 'downloads' && (
          <Group c={c}>
            <Row c={c} label="Save downloads to" last="first"><Popup c={c}><Icon d={P.folder} size={13} color={c.sec} /> Downloads</Popup></Row>
            <Row c={c} label="Automatic connections" sub="Learns the best count per host"><Switch on={s.autoConn} onClick={() => set('autoConn')} c={c} /></Row>
            {!s.autoConn && <Row c={c} label="Parallel connections"><Stepper value={s.conns} onChange={(v) => setS((o) => ({ ...o, conns: v }))} c={c} /></Row>}
            <Row c={c} label="Pause on cellular networks"><Switch on={s.cellular} onClick={() => set('cellular')} c={c} /></Row>
          </Group>
        )}
        {tab === 'trust' && (
          <Group c={c}>
            <Row c={c} label="Record provenance" sub="Every download is hashed and logged. Always on." last="first">
              <span style={{ fontSize: 12, color: c.green, fontWeight: 500 }}>On</span>
            </Row>
            <Row c={c} label="Verify ledger at launch"><Switch on={s.verifyLaunch} onClick={() => set('verifyLaunch')} c={c} /></Row>
            <Row c={c} label="Attestation key" sub="Secure Enclave · never leaves this Mac"><PushBtn c={c}>Regenerate…</PushBtn></Row>
          </Group>
        )}
        {tab === 'advanced' && (
          <Group c={c}>
            <Row c={c} label="Authenticated downloads" sub="Import cookies from Safari for gated files" last="first"><PushBtn c={c}>Import…</PushBtn></Row>
            <Row c={c} label="Reset host scheduling"><PushBtn c={c}>Reset…</PushBtn></Row>
            <Row c={c} label="Engine trace logging" sub="Verbose scheduler diagnostics"><Switch on={s.trace} onClick={() => set('trace')} c={c} /></Row>
          </Group>
        )}
      </div>
      <div style={{ padding: '4px 20px 16px', fontSize: 11, color: c.ter }}>goh 0.1 · macOS 26 · Apple Silicon</div>
    </AWindow>
  );
}

// ── Downloads window (the "All Downloads" / "Show All" destination) ─────────
if (!document.getElementById('goh-scroll-style')) {
  const s = document.createElement('style');
  s.id = 'goh-scroll-style';
  s.textContent = `
    .goh-scroll{ overflow-y:auto; scrollbar-width:thin; }
    .goh-scroll::-webkit-scrollbar{ width:9px; }
    .goh-scroll::-webkit-scrollbar-thumb{ background:rgba(140,140,150,0.45); border-radius:5px; border:2px solid transparent; background-clip:content-box; }
    .goh-scroll::-webkit-scrollbar-thumb:hover{ background:rgba(140,140,150,0.7); border:2px solid transparent; background-clip:content-box; }
    .goh-scroll::-webkit-scrollbar-track{ background:transparent; }
  `;
  document.head.appendChild(s);
}

const DL_ACTIVE = [
  { id: 1, name: 'llama-3.1-70b-instruct.safetensors', host: 'huggingface.co', pct: 62, done: '42.6', total: '68.4 GB', speed: '5.1 MB/s', eta: '1m 12s', state: 'active' },
  { id: 2, name: 'imagenet-val.tar.zst', host: 'image-net.org', pct: 28, done: '1.79', total: '6.40 GB', speed: '1.3 MB/s', eta: '4m 03s', state: 'active' },
  { id: 3, name: 'dataset-shard-00007.parquet', host: 'data.example.com', pct: 0, total: '512 MB', state: 'queued' },
];
const DL_DONE = [
  { id: 5, name: 'sd-xl-base-1.0.safetensors', host: 'huggingface.co', size: '6.94 GB', date: 'Today, 9:32 AM', state: 'completed', sha: 'a1f3…9c20' },
  { id: 6, name: 'config.json', host: 'huggingface.co', size: '4.2 KB', date: 'Today, 9:30 AM', state: 'completed', sha: '77be…01da' },
  { id: 7, name: 'tokenizer.model', host: 'huggingface.co', size: '2.1 MB', date: 'Today, 9:14 AM', state: 'completed', sha: 'b820…1a4c' },
  { id: 9, name: 'mistral-7b-v0.3.safetensors', host: 'huggingface.co', size: '14.5 GB', date: 'Yesterday, 2:20 PM', state: 'completed', sha: '3d9a…ee47' },
  { id: 10, name: 'clip-vit-large-patch14.bin', host: 'huggingface.co', size: '1.7 GB', date: 'Jun 6', state: 'completed', sha: '5c1f…77b2' },
  { id: 11, name: 'coco-annotations-2017.zip', host: 'cocodataset.org', size: '241 MB', date: 'Jun 5', state: 'completed', sha: '9911…34de' },
  { id: 12, name: 'whisper-large-v3.pt', host: 'openai-cdn.com', size: '3.09 GB', date: 'Jun 4', state: 'completed', sha: '00aa…9f31' },
  { id: 13, name: 'roberta-base.safetensors', host: 'huggingface.co', size: '498 MB', date: 'Jun 3', state: 'completed', sha: 'b1c2…77aa' },
  { id: 14, name: 'segment-anything-vit-h.pth', host: 'meta.com', size: '2.56 GB', date: 'Jun 2', state: 'completed', sha: 'ee47…0c20' },
];
const DL_FAILED = [
  { id: 8, name: 'vocab.bpe', host: 'cdn.example.com', size: '1.0 MB', date: 'Yesterday, 6:02 PM', state: 'failed', err: 'Server returned 503' },
  { id: 15, name: 'pretrain-corpus-shard-12.jsonl.gz', host: 'data.example.com', size: '880 MB', date: 'Jun 1', state: 'failed', err: 'Checksum mismatch' },
];

function Seg({ value, options, onChange, c }) {
  return (
    <div style={{ display: 'inline-flex', padding: 2, borderRadius: 8, background: c.dark ? 'rgba(0,0,0,0.25)' : 'rgba(0,0,0,0.06)' }}>
      {options.map(([v, label]) => {
        const on = value === v;
        return (
          <button key={v} className="goh-btn" onClick={() => onChange(v)} style={{ border: 'none', cursor: 'pointer', padding: '4px 12px', borderRadius: 6, fontFamily: SF, fontSize: 12, fontWeight: on ? 600 : 500,
            background: on ? (c.dark ? 'rgba(255,255,255,0.14)' : '#fff') : 'transparent', color: on ? c.label : c.sec, boxShadow: on && !c.dark ? '0 0.5px 2px rgba(0,0,0,0.18)' : 'none' }}>{label}</button>
        );
      })}
    </div>
  );
}

function DLRow({ e, c, top, onToggle }) {
  const [h, setH] = useState(false);
  const [stem, ext] = splitName(e.name);
  const active = e.state === 'active', queued = e.state === 'queued', failed = e.state === 'failed';
  const live = active || queued;
  return (
    <div className="goh-row-hit" onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 16px', borderTop: top ? `0.5px solid ${c.sep}` : 'none', background: h ? c.rowHover : 'transparent' }}>
      {/* leading status icon */}
      <span style={{ width: 30, height: 30, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: failed ? (c.dark ? 'rgba(255,69,58,0.14)' : 'rgba(255,59,48,0.1)') : live ? 'rgba(52,210,102,0.14)' : (c.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)') }}>
        {failed ? <Icon d="M12 2a10 10 0 100 20 10 10 0 000-20z M12 7v6 M12 16.5v.5" size={16} sw={1.7} color={c.red} />
          : live ? <Icon d="M12 4v10 M8 11l4 3 4-3 M6 19h12" size={16} sw={1.7} color={c.green} />
          : <Icon d="M12 2a10 10 0 100 20 10 10 0 000-20z M8.5 12l2.5 2.5 4.5-5" size={17} sw={1.7} color={c.green} />}
      </span>
      {/* body */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, color: c.label, fontWeight: 400, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{stem}{ext}</div>
        {active && <div style={{ margin: '6px 0 5px' }}><AppleBar pct={e.pct} color={c.green} track={c.track} /></div>}
        {queued && <div style={{ margin: '6px 0 5px' }}><AppleBar pct={0} color={c.green} track={c.track} /></div>}
        <div style={{ fontSize: 11, color: failed ? c.red : c.sec, ...NUM }}>
          {active ? `${e.done} of ${e.total} — ${e.speed} — ${e.eta} left`
            : queued ? 'Waiting…'
            : failed ? `${e.err || 'Failed'} — ${e.host}`
            : `${e.host} · ${e.size} · sha256 ${e.sha}`}
        </div>
      </div>
      {/* trailing */}
      <div style={{ flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8 }}>
        {!live && !failed && <span style={{ fontSize: 11.5, color: c.sec, ...NUM, marginRight: 2 }}>{e.date}</span>}
        {live && <CircleCtrl kind={queued ? 'play' : 'pause'} color={c.sec} ring={c.sep} onClick={() => onToggle && onToggle(e.id)} />}
        {failed && <button className="goh-btn" style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '5px 11px', borderRadius: 7, border: 'none', cursor: 'pointer', background: c.dark ? 'rgba(255,255,255,0.1)' : '#fff', color: c.label, fontFamily: SF, fontSize: 12, fontWeight: 600, boxShadow: c.dark ? 'none' : '0 0.5px 2px rgba(0,0,0,0.15)' }}>Retry</button>}
        {!live && h && <RowGlyphBtn d={P.folder} c={c} title="Reveal in Finder" />}
      </div>
    </div>
  );
}

function SectionHead({ children, right, c }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', padding: '14px 16px 6px' }}>
      <span style={{ fontSize: 11.5, fontWeight: 600, color: c.sec, textTransform: 'uppercase', letterSpacing: '0.04em' }}>{children}</span>
      {right && <span style={{ fontFamily: SF, fontSize: 11, color: c.ter, ...NUM }}>{right}</span>}
    </div>
  );
}

function AppleDownloadsWindow({ mode = 'dark' }) {
  const c = winTokens(mode === 'dark');
  const [filter, setFilter] = useState('all');
  const [jobs, setJobs] = useState(DL_ACTIVE);
  const toggle = (id) => setJobs((js) => js.map((j) => j.id === id ? { ...j, state: j.state === 'active' ? 'queued' : 'active' } : j));
  const showActive = filter === 'all' || filter === 'active';
  const showDone = filter === 'all' || filter === 'done';
  const showFailed = filter === 'all' || filter === 'failed';

  return (
    <AWindow width={660} title="Downloads" c={c} toolbar={
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '0 16px 12px' }}>
        <Seg value={filter} c={c} onChange={setFilter} options={[['all', 'All'], ['active', 'Downloading'], ['done', 'Completed'], ['failed', 'Failed']]} />
        <span style={{ flex: 1 }} />
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '5px 10px', borderRadius: 8, background: c.dark ? 'rgba(0,0,0,0.25)' : '#fff', boxShadow: `inset 0 0 0 0.5px ${c.sep}`, width: 170 }}>
          <Icon d={P.search} size={13} color={c.ter} /><span style={{ fontSize: 12, color: c.ter }}>Search downloads</span>
        </span>
      </div>
    }>
      <div className="goh-scroll" style={{ height: 408, borderTop: `0.5px solid ${c.sep}` }}>
        {showActive && (
          <>
            <SectionHead c={c} right={`${jobs.filter((j) => j.state === 'active').length} active`}>Downloading</SectionHead>
            <div style={{ margin: '0 12px', borderRadius: 13, background: c.card, overflow: 'hidden', boxShadow: c.cardShadow }}>
              {jobs.map((e, i) => <DLRow key={e.id} e={e} c={c} top={i > 0} onToggle={toggle} />)}
            </div>
          </>
        )}
        {showDone && (
          <>
            <SectionHead c={c} right="46 total">{filter === 'done' ? 'Completed' : 'Recent'}</SectionHead>
            <div style={{ margin: '0 12px 14px', borderRadius: 13, background: c.card, overflow: 'hidden', boxShadow: c.cardShadow }}>
              {DL_DONE.map((e, i) => <DLRow key={e.id} e={e} c={c} top={i > 0} />)}
            </div>
          </>
        )}
        {showFailed && (
          <>
            <SectionHead c={c} right={`${DL_FAILED.length} failed`}>Failed</SectionHead>
            <div style={{ margin: '0 12px 14px', borderRadius: 13, background: c.card, overflow: 'hidden', boxShadow: c.cardShadow }}>
              {DL_FAILED.map((e, i) => <DLRow key={e.id} e={e} c={c} top={i > 0} />)}
            </div>
          </>
        )}
      </div>

      {/* footer summary */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 16px', borderTop: `0.5px solid ${c.sep}` }}>
        <span style={{ fontSize: 11.5, color: c.sec, ...NUM }}>48 downloads · 3 active · 109 GB total</span>
        <span style={{ flex: 1 }} />
        <button className="goh-btn" style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 12px', borderRadius: 8, border: `0.5px solid ${c.hair}`, background: c.fill, color: c.label, fontFamily: SF, fontSize: 12, fontWeight: 500, cursor: 'pointer' }}>
          <Icon d={P.folder} size={13} color={c.sec} /> Open Folder
        </button>
        <button className="goh-btn" style={{ padding: '6px 12px', borderRadius: 8, border: `0.5px solid ${c.hair}`, background: c.fill, color: c.label, fontFamily: SF, fontSize: 12, fontWeight: 500, cursor: 'pointer' }}>Clear Completed</button>
      </div>
    </AWindow>
  );
}

Object.assign(window, { AppleAddWindow, AppleTrustWindow, ApplePrefsWindow, AppleDownloadsWindow, winTokens });
