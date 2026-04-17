import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { usePlatform } from '../../lib/PlatformContext'

interface Props {
  children: string
  className?: string
}

export default function Markdown({ children, className = '' }: Props) {
  const { themeMode } = usePlatform()
  const isDark = themeMode === 'dark'

  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      className={`prose ${isDark ? 'prose-invert' : ''} prose-sm max-w-none ${className}`}
      components={{
        p: ({ children }) => <p className="mb-1.5 last:mb-0 text-sm leading-snug text-ask-text">{children}</p>,
        h1: ({ children }) => <h1 className="text-base font-semibold mb-2 text-ask-text">{children}</h1>,
        h2: ({ children }) => <h2 className="text-sm font-semibold mb-1 text-ask-text">{children}</h2>,
        h3: ({ children }) => <h3 className="text-sm font-semibold mb-1 text-ask-text">{children}</h3>,
        ul: ({ children }) => <ul className="list-disc list-inside mb-2 space-y-0.5">{children}</ul>,
        ol: ({ children }) => <ol className="list-decimal list-inside mb-2 space-y-0.5">{children}</ol>,
        li: ({ children }) => <li className="text-sm text-ask-text">{children}</li>,
        code: ({ children, className }) => {
          const isBlock = className?.includes('language-')
          return isBlock
            ? <code className="block bg-ask-card2 rounded p-2 text-xs font-mono overflow-x-auto whitespace-pre text-ask-text">{children}</code>
            : <code className="bg-ask-card2 rounded px-1 text-xs font-mono text-ask-text">{children}</code>
        },
        pre: ({ children }) => <pre className="mb-2">{children}</pre>,
        strong: ({ children }) => <strong className="font-semibold text-ask-text">{children}</strong>,
        blockquote: ({ children }) => <blockquote className="border-l-2 border-ask-sep pl-3 text-ask-secondary">{children}</blockquote>,
      }}
    >
      {children}
    </ReactMarkdown>
  )
}
