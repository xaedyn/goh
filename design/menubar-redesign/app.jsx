/* app.jsx — compose the three directions into a design canvas */
/* eslint-disable */

const DARK_BG = `
  radial-gradient(130% 80% at 82% -8%, #213244 0%, rgba(33,50,68,0) 52%),
  radial-gradient(95% 70% at 0% 108%, #2b2540 0%, rgba(43,37,64,0) 50%),
  linear-gradient(165deg, #11141b 0%, #0b0d12 58%, #08090d 100%)`;

function DarkPanel({ width, height, children, center }) {
  return (
    <div style={{ width, height, position: 'relative', overflow: 'hidden', background: DARK_BG, fontFamily: FONT.ui,
      display: center ? 'flex' : 'block', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ position: 'absolute', inset: 0, opacity: 0.5, pointerEvents: 'none',
        backgroundImage: 'radial-gradient(rgba(255,255,255,0.018) 1px, transparent 1px)', backgroundSize: '3px 3px' }} />
      <div style={{ position: 'relative', width: '100%' }}>{children}</div>
    </div>
  );
}

function NotifScene({ width, height, Comp }) {
  return (
    <MenuBarScene width={width} height={height} glyphState="done" clock="9:41 AM">
      <div style={{ position: 'absolute', top: 38, right: 14, zIndex: 4 }}><Comp /></div>
    </MenuBarScene>
  );
}

const POP_W = 620, POP_H = 900;
const ICON_W = 488, ICON_H = 372;
const NOTIF_W = 470, NOTIF_H = 220;
const ADDW = 520, ADDH = 470;
const TRUSTW = 772, TRUSTH = 560;

function App() {
  return (
    <DesignCanvas>
      <DCSection id="D" title="D · Manifest  ·  recommended" subtitle="The chosen hybrid — Ledger's provenance soul + Telemetry's live density + Focus's arrow accent. Carried through to both windows.">
        <DCArtboard id="d-pop" label="Popover · live" width={POP_W} height={POP_H} style={{ background: '#0b0d12' }}>
          <MenuBarScene width={POP_W} height={POP_H} glyphState="active"><ManifestPopover /></MenuBarScene>
        </DCArtboard>
        <DCArtboard id="d-add" label="Add Download window" width={ADDW} height={ADDH} style={{ background: '#0b0d12' }}>
          <DarkPanel width={ADDW} height={ADDH} center><div style={{ display: 'flex', justifyContent: 'center' }}><AddDownloadWindow /></div></DarkPanel>
        </DCArtboard>
        <DCArtboard id="d-trust" label="Trust window" width={TRUSTW} height={TRUSTH} style={{ background: '#0b0d12' }}>
          <DarkPanel width={TRUSTW} height={TRUSTH} center><div style={{ display: 'flex', justifyContent: 'center' }}><TrustWindow /></div></DarkPanel>
        </DCArtboard>
        <DCArtboard id="d-prefs" label="Preferences window" width={ADDW} height={ADDH} style={{ background: '#0b0d12' }}>
          <DarkPanel width={ADDW} height={ADDH} center><div style={{ display: 'flex', justifyContent: 'center' }}><PreferencesWindow /></div></DarkPanel>
        </DCArtboard>
        <DCArtboard id="d-icon" label="Menu bar icon · 5 states" width={ICON_W} height={ICON_H} style={{ background: '#0b0d12' }}>
          <DarkPanel width={ICON_W} height={ICON_H}><IconStatesStripB /></DarkPanel>
        </DCArtboard>
        <DCArtboard id="d-notif" label="Completion notification" width={NOTIF_W} height={NOTIF_H} style={{ background: '#0b0d12' }}>
          <NotifScene width={NOTIF_W} height={NOTIF_H} Comp={LedgerNotification} />
        </DCArtboard>
      </DCSection>

      <DCSection id="A" title="A · Telemetry" subtitle="Instrument-panel density — every transfer is a live readout; aggregate throughput gauge up top.">
        <DCArtboard id="a-pop" label="Popover · live" width={POP_W} height={POP_H} style={{ background: '#0b0d12' }}>
          <MenuBarScene width={POP_W} height={POP_H} glyphState="active"><TelemetryPopover /></MenuBarScene>
        </DCArtboard>
        <DCArtboard id="a-icon" label="Menu bar icon · 5 states" width={ICON_W} height={ICON_H} style={{ background: '#0b0d12' }}>
          <DarkPanel width={ICON_W} height={ICON_H}><IconStatesStrip /></DarkPanel>
        </DCArtboard>
        <DCArtboard id="a-notif" label="Completion notification" width={NOTIF_W} height={NOTIF_H} style={{ background: '#0b0d12' }}>
          <NotifScene width={NOTIF_W} height={NOTIF_H} Comp={TelemetryNotification} />
        </DCArtboard>
      </DCSection>

      <DCSection id="B" title="B · Ledger" subtitle="Editorial, provenance-forward — goh is a lockfile, so trust is the visual story: sha stubs, verified marks, manifest rhythm.">
        <DCArtboard id="b-pop" label="Popover · live" width={POP_W} height={POP_H} style={{ background: '#0b0d12' }}>
          <MenuBarScene width={POP_W} height={POP_H} glyphState="active"><LedgerPopover /></MenuBarScene>
        </DCArtboard>
        <DCArtboard id="b-icon" label="Menu bar icon · 5 states" width={ICON_W} height={ICON_H} style={{ background: '#0b0d12' }}>
          <DarkPanel width={ICON_W} height={ICON_H}><IconStatesStripB /></DarkPanel>
        </DCArtboard>
        <DCArtboard id="b-notif" label="Completion notification" width={NOTIF_W} height={NOTIF_H} style={{ background: '#0b0d12' }}>
          <NotifScene width={NOTIF_W} height={NOTIF_H} Comp={LedgerNotification} />
        </DCArtboard>
      </DCSection>

      <DCSection id="C" title="C · Focus" subtitle="The active download is the hero — the brand's phosphor arrow becomes the progress bar. Rich active moment, calm list below.">
        <DCArtboard id="c-pop" label="Popover · live" width={POP_W} height={POP_H} style={{ background: '#0b0d12' }}>
          <MenuBarScene width={POP_W} height={POP_H} glyphState="active"><FocusPopover /></MenuBarScene>
        </DCArtboard>
        <DCArtboard id="c-icon" label="Menu bar icon · 5 states" width={ICON_W} height={ICON_H} style={{ background: '#0b0d12' }}>
          <DarkPanel width={ICON_W} height={ICON_H}><IconStatesStripC /></DarkPanel>
        </DCArtboard>
        <DCArtboard id="c-notif" label="Completion notification" width={NOTIF_W} height={NOTIF_H} style={{ background: '#0b0d12' }}>
          <NotifScene width={NOTIF_W} height={NOTIF_H} Comp={FocusNotification} />
        </DCArtboard>
      </DCSection>
    </DesignCanvas>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
