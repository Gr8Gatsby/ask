import React, { useEffect, useState } from 'react'
import { usePlatform } from '../lib/PlatformContext'
import { useSettings } from '../lib/SettingsContext'
import { getMachines } from '../lib/api'
import type { Machine } from '../lib/types'
import { IOSStatusBarRow, iosNavChromeStyle } from '../components/layout/AppShell'

// ---- iOS Settings primitives ----

function IOSSectionHeader({ label }: { label: string }) {
  return (
    <p className="text-[13px] text-ask-secondary uppercase tracking-wide px-4 pb-1 pt-5 first:pt-3">
      {label}
    </p>
  )
}

// Inset grouped card container
function IOSListCard({ children }: { children: React.ReactNode }) {
  return (
    <div className="mx-4 bg-ask-card rounded-xl overflow-hidden shadow-sm shadow-black/[0.06]">
      {children}
    </div>
  )
}

// Inset separator
function IOSSep() {
  return <div className="h-px bg-ask-sep/50 ml-4 mr-4" />
}

function IOSSectionFooter({ text }: { text: string }) {
  return (
    <p className="text-[13px] text-ask-secondary px-4 pt-1 pb-1 leading-relaxed">{text}</p>
  )
}

interface IOSRowProps {
  label: string
  value?: string
  chevron?: boolean
  first?: boolean
  last?: boolean
  destructive?: boolean
  children?: React.ReactNode
  onTap?: () => void
}

function IOSRow({ label, value, chevron, destructive, children, onTap }: Omit<IOSRowProps, 'first' | 'last'>) {
  return (
    <div
      onClick={onTap}
      className={`flex items-center min-h-[44px] px-4 ${onTap ? 'active:bg-ask-sep/30 cursor-pointer transition-colors' : ''}`}
    >
      <span className={`flex-1 text-[17px] font-normal ${destructive ? 'text-red-500' : 'text-ask-text'}`}>{label}</span>
      {value && <span className="text-[17px] text-ask-secondary mr-2">{value}</span>}
      {children}
      {chevron && (
        <svg width="6" height="10" viewBox="0 0 6 10" fill="none" className="ml-1 text-ask-secondary/45 flex-shrink-0">
          <path d="M1 1l4 4-4 4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      )}
    </div>
  )
}

function IOSToggle({ on, onToggle }: { on: boolean; onToggle: () => void }) {
  return (
    <button
      onClick={onToggle}
      className={`relative w-[51px] h-[31px] rounded-full transition-colors duration-200 flex-shrink-0 ${on ? 'bg-ask-green' : 'bg-ask-secondary/20'}`}
      style={{ WebkitTapHighlightColor: 'transparent' }}
    >
      <span
        className="absolute top-[2px] w-[27px] h-[27px] bg-white rounded-full shadow-sm transition-all duration-200"
        style={{ left: on ? '22px' : '2px' }}
      />
    </button>
  )
}

// ---- Android Settings primitives ----

function AndroidCategoryHeader({ label }: { label: string }) {
  return (
    <p className="text-[13px] font-medium text-ask-blue px-4 pt-5 pb-1 first:pt-4">{label}</p>
  )
}

interface AndroidPrefProps {
  title: string
  summary?: string
  last?: boolean
  children?: React.ReactNode
  onTap?: () => void
}

function AndroidPref({ title, summary, last, children, onTap }: AndroidPrefProps) {
  return (
    <>
      <button
        onClick={onTap}
        className="w-full flex items-center gap-4 px-4 min-h-[64px] active:bg-ask-card2 transition-colors text-left"
      >
        <div className="flex-1">
          <p className="text-[16px] font-normal text-ask-text leading-snug">{title}</p>
          {summary && <p className="text-[14px] text-ask-secondary leading-snug mt-0.5">{summary}</p>}
        </div>
        {children}
      </button>
      {!last && <div className="h-px bg-ask-sep/20 mx-4" />}
    </>
  )
}

function AndroidToggle({ on, onToggle }: { on: boolean; onToggle: () => void }) {
  return (
    <button
      onClick={e => { e.stopPropagation(); onToggle() }}
      className={`relative flex-shrink-0 w-[52px] h-[32px] rounded-full transition-colors duration-200 border-2 ${
        on ? 'bg-ask-blue border-ask-blue' : 'bg-transparent border-ask-secondary/50'
      }`}
      style={{ WebkitTapHighlightColor: 'transparent' }}
    >
      <span
        className={`absolute top-1/2 -translate-y-1/2 rounded-full transition-all duration-200 ${
          on ? 'w-[24px] h-[24px] bg-white' : 'w-[16px] h-[16px] bg-ask-secondary/70'
        }`}
        style={{ left: on ? '22px' : '6px' }}
      />
    </button>
  )
}

// ---- Machine detail sheet ----

function MachineDetailSheet({ machine, onDismiss }: { machine: Machine; onDismiss: () => void }) {
  return (
    <div className="absolute inset-0 z-50 flex items-end">
      <div className="absolute inset-0 bg-black/40" onClick={onDismiss} />
      <div className="relative w-full bg-ask-bg rounded-t-2xl pb-8 pt-2 px-4 max-h-[60vh] overflow-y-auto">
        <div className="w-10 h-1 bg-ask-secondary/30 rounded-full mx-auto mb-4" />
        <h2 className="text-[22px] font-semibold text-ask-text mb-4">{machine.name}</h2>
        <div className="rounded-xl overflow-hidden">
          <div className="flex items-center min-h-[44px] px-4 bg-ask-card border-b border-ask-sep/40">
            <span className="flex-1 text-[17px] text-ask-text">Machine ID</span>
            <span className="text-[13px] text-ask-secondary font-mono">{machine.machineID.slice(0, 8)}…</span>
          </div>
          <div className="flex items-center min-h-[44px] px-4 bg-ask-card border-b border-ask-sep/40">
            <span className="flex-1 text-[17px] text-ask-text">Platform</span>
            <span className="text-[17px] text-ask-secondary">{machine.platform}</span>
          </div>
          <div className="flex items-center min-h-[44px] px-4 bg-ask-card">
            <span className="flex-1 text-[17px] text-ask-text">Status</span>
            <span className={`text-[17px] ${machine.status === 'busy' ? 'text-ask-blue' : 'text-ask-secondary'}`}>
              {machine.status === 'busy' ? 'Active' : 'Idle'}
            </span>
          </div>
        </div>
        <p className="text-[13px] text-ask-secondary px-1 pt-2 leading-relaxed">
          A running Mac re-registers within 30 seconds.
        </p>
      </div>
    </div>
  )
}

// ---- Computer filter sheet ----

function ComputerFilterSheet({
  machines,
  selectedMachineID,
  onSelect,
  onDismiss,
}: {
  machines: Machine[]
  selectedMachineID: string | null
  onSelect: (id: string | null) => void
  onDismiss: () => void
}) {
  return (
    <div className="absolute inset-0 z-50 flex items-end">
      <div className="absolute inset-0 bg-black/40" onClick={onDismiss} />
      <div className="relative w-full bg-ask-bg rounded-t-2xl pb-8 pt-2 px-4 max-h-[60vh] overflow-y-auto">
        <div className="w-10 h-1 bg-ask-secondary/30 rounded-full mx-auto mb-4" />
        <h2 className="text-[22px] font-semibold text-ask-text mb-4">Computer</h2>
        <div className="rounded-xl overflow-hidden">
          {/* All computers option */}
          <button
            onClick={() => { onSelect(null); onDismiss() }}
            className="w-full flex items-center min-h-[44px] px-4 bg-ask-card border-b border-ask-sep/40 active:opacity-70"
          >
            <span className="flex-1 text-[17px] text-ask-text text-left">All Computers</span>
            {selectedMachineID === null && (
              <span className="mat-icon text-ask-blue" style={{ fontSize: 20, fontVariationSettings: "'FILL' 1" }}>check</span>
            )}
          </button>
          {machines.map((m, i) => (
            <button
              key={m.machineID}
              onClick={() => { onSelect(m.machineID); onDismiss() }}
              className={`w-full flex items-center min-h-[44px] px-4 bg-ask-card active:opacity-70 ${i < machines.length - 1 ? 'border-b border-ask-sep/40' : ''}`}
            >
              <span className="flex-1 text-[17px] text-ask-text text-left">{m.name}</span>
              {selectedMachineID === m.machineID && (
                <span className="mat-icon text-ask-blue" style={{ fontSize: 20, fontVariationSettings: "'FILL' 1" }}>check</span>
              )}
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

// ---- Screen ----

export default function SettingsScreen() {
  const { platform, themeMode } = usePlatform()
  const isAndroid = platform === 'android'

  const { useBrandColors, setUseBrandColors, selectedMachineID, setSelectedMachineID } = useSettings()
  const [machines, setMachines] = useState<Machine[]>([])
  const [selectedMachine, setSelectedMachine] = useState<Machine | null>(null)
  const [showComputerFilter, setShowComputerFilter] = useState(false)

  const selectedMachineName = selectedMachineID
    ? (machines.find(m => m.machineID === selectedMachineID)?.name ?? 'Unknown')
    : 'All'

  useEffect(() => {
    getMachines().then(setMachines).catch(() => {})
  }, [])

  if (isAndroid) {
    return (
      <div className="flex flex-col h-full overflow-y-auto no-scrollbar bg-ask-bg">
        <div className="px-4 pt-4 pb-3">
          <h1 className="text-[28px] font-medium text-ask-text leading-tight">Settings</h1>
        </div>

        <AndroidCategoryHeader label="Machines" />
        <AndroidPref
          title="Computer"
          summary={selectedMachineName === 'All' ? 'All Computers' : selectedMachineName}
          onTap={() => setShowComputerFilter(true)}
        >
          <svg width="8" height="13" viewBox="0 0 8 13" fill="none" className="text-ask-secondary/50">
            <path d="M1 1l6 5.5L1 12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </AndroidPref>
        {machines.map((m, i) => (
          <AndroidPref
            key={m.machineID}
            title={m.name}
            summary={m.status === 'busy' ? 'Active' : 'Idle'}
            last={i === machines.length - 1}
            onTap={() => setSelectedMachine(m)}
          >
            <svg width="8" height="13" viewBox="0 0 8 13" fill="none" className="text-ask-secondary/50">
              <path d="M1 1l6 5.5L1 12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </AndroidPref>
        ))}

        <AndroidCategoryHeader label="Appearance" />
        <AndroidPref title="Script Brand Colors" summary="Show script accent colors on cards" last>
          <AndroidToggle on={useBrandColors} onToggle={() => setUseBrandColors(!useBrandColors)} />
        </AndroidPref>

        <AndroidCategoryHeader label="Developer" />
        <AndroidPref title="CloudKit Environment" summary="Development" />
        <AndroidPref title="App Version" summary="0.1.0 (1)" last />

        <div className="h-8" />

        {selectedMachine && (
          <MachineDetailSheet machine={selectedMachine} onDismiss={() => setSelectedMachine(null)} />
        )}
        {showComputerFilter && (
          <ComputerFilterSheet
            machines={machines}
            selectedMachineID={selectedMachineID}
            onSelect={setSelectedMachineID}
            onDismiss={() => setShowComputerFilter(false)}
          />
        )}
      </div>
    )
  }

  // iOS — frosted glass chrome + inset grouped table style
  const isLight = themeMode === 'light'
  return (
    <div className="relative h-full bg-ask-bg">
      <div
        className="absolute top-0 left-0 right-0 z-20"
        style={iosNavChromeStyle(isLight)}
      >
        <IOSStatusBarRow />
        <div className="flex items-center justify-center px-4 pb-3">
          <p className="text-[17px] font-semibold text-ask-text">Settings</p>
        </div>
      </div>

      <div className="absolute inset-0 overflow-y-auto no-scrollbar">
        <div className="pt-24">
          {/* Machines section */}
          <IOSSectionHeader label="Machines" />
          <IOSListCard>
            <IOSRow label="Computer" value={selectedMachineName} chevron onTap={() => setShowComputerFilter(true)} />
            {machines.map(m => (
              <React.Fragment key={m.machineID}>
                <IOSSep />
                <IOSRow label={m.name} value={m.status === 'busy' ? 'Active' : 'Idle'} chevron onTap={() => setSelectedMachine(m)} />
              </React.Fragment>
            ))}
          </IOSListCard>
          <IOSSectionFooter text="Filter to a single computer or view all. A running Mac re-registers within 30 seconds." />

          {/* Appearance section */}
          <IOSSectionHeader label="Appearance" />
          <IOSListCard>
            <IOSRow label="Script Brand Colors">
              <IOSToggle on={useBrandColors} onToggle={() => setUseBrandColors(!useBrandColors)} />
            </IOSRow>
          </IOSListCard>

          {/* Developer section */}
          <IOSSectionHeader label="Developer" />
          <IOSListCard>
            <IOSRow label="CloudKit Environment" value="Development" />
            <IOSSep />
            <IOSRow label="App Version" value="0.1.0 (1)" />
          </IOSListCard>

          <div className="h-8" />
        </div>
      </div>

      {selectedMachine && (
        <MachineDetailSheet machine={selectedMachine} onDismiss={() => setSelectedMachine(null)} />
      )}
      {showComputerFilter && (
        <ComputerFilterSheet
          machines={machines}
          selectedMachineID={selectedMachineID}
          onSelect={setSelectedMachineID}
          onDismiss={() => setShowComputerFilter(false)}
        />
      )}
    </div>
  )
}
