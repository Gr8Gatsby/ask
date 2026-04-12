import { useLocation, useNavigate } from 'react-router-dom'

interface Props { children: React.ReactNode }

export default function AppShell({ children }: Props) {
  const location = useLocation()
  const navigate = useNavigate()

  const tab = location.pathname.startsWith('/tasks') ? 'tasks'
    : location.pathname.startsWith('/catalog') ? 'catalog'
    : 'home'

  return (
    // Center a 390px phone-width column — mirrors iPhone 16 width
    <div className="h-full flex justify-center bg-black">
      <div className="w-full max-w-[390px] flex flex-col h-full bg-ask-bg relative overflow-hidden">
        {/* Screen content */}
        <div className="flex-1 overflow-y-auto no-scrollbar">
          {children}
        </div>

        {/* Tab bar */}
        <div className="flex-shrink-0 border-t border-ask-sep bg-ask-bg/95 backdrop-blur-sm">
          <div className="flex items-center">
            {[
              { key: 'home', label: 'Home', icon: '⊞', path: '/home' },
              { key: 'tasks', label: 'Feed', icon: '◈', path: '/tasks' },
              { key: 'catalog', label: 'Catalog', icon: '⊟', path: '/catalog' },
            ].map(item => (
              <button
                key={item.key}
                onClick={() => navigate(item.path)}
                className={`flex-1 flex flex-col items-center gap-0.5 py-2 text-[10px] transition-colors ${
                  tab === item.key ? 'text-ask-blue' : 'text-ask-secondary'
                }`}
              >
                <span className="text-lg leading-none">{item.icon}</span>
                <span>{item.label}</span>
              </button>
            ))}
          </div>
          {/* Home indicator */}
          <div className="flex justify-center pb-1">
            <div className="w-28 h-1 rounded-full bg-white/20" />
          </div>
        </div>
      </div>
    </div>
  )
}
