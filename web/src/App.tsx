import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import AppShell from './components/layout/AppShell'
import HomeScreen from './screens/HomeScreen'
import ScriptDetailScreen from './screens/ScriptDetailScreen'
import SessionChatScreen from './screens/SessionChatScreen'
import TaskFeedScreen from './screens/TaskFeedScreen'
import TaskThreadScreen from './screens/TaskThreadScreen'
import CatalogScreen from './screens/CatalogScreen'

export default function App() {
  return (
    <BrowserRouter>
      <AppShell>
        <Routes>
          <Route path="/" element={<Navigate to="/home" replace />} />
          <Route path="/home" element={<HomeScreen />} />
          <Route path="/script/:scriptID" element={<ScriptDetailScreen />} />
          <Route path="/script/:scriptID/session/:sessionID" element={<SessionChatScreen />} />
          <Route path="/tasks" element={<TaskFeedScreen />} />
          <Route path="/tasks/:taskID" element={<TaskThreadScreen />} />
          <Route path="/catalog" element={<CatalogScreen />} />
        </Routes>
      </AppShell>
    </BrowserRouter>
  )
}
