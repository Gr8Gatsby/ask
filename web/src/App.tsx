import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { PlatformProvider } from './lib/PlatformContext'
import { SettingsProvider } from './lib/SettingsContext'
import { StartSessionProvider } from './lib/StartSessionContext'
import AppShell from './components/layout/AppShell'
import HomeScreen from './screens/HomeScreen'
import ScriptDetailScreen from './screens/ScriptDetailScreen'
import SessionChatScreen from './screens/SessionChatScreen'
import TaskFeedScreen from './screens/TaskFeedScreen'
import TaskThreadScreen from './screens/TaskThreadScreen'
import SettingsScreen from './screens/SettingsScreen'

export default function App() {
  return (
    <StartSessionProvider>
    <SettingsProvider>
    <PlatformProvider>
      <BrowserRouter>
        <AppShell>
          <Routes>
            <Route path="/" element={<Navigate to="/home" replace />} />
            <Route path="/home" element={<HomeScreen />} />
            <Route path="/script/:scriptID" element={<ScriptDetailScreen />} />
            <Route path="/script/:scriptID/session/:sessionID" element={<SessionChatScreen />} />
            <Route path="/tasks" element={<TaskFeedScreen />} />
            <Route path="/tasks/:taskID" element={<TaskThreadScreen />} />
            <Route path="/settings" element={<SettingsScreen />} />
          </Routes>
        </AppShell>
      </BrowserRouter>
    </PlatformProvider>
    </SettingsProvider>
    </StartSessionProvider>
  )
}
