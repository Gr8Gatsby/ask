import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { usePlatform } from '../../lib/PlatformContext'

interface Props {
  children: string
  className?: string
}

// GitHub-flavoured markdown rendering for assistant messages.
// Styling parallels github.com:
//   - Headings: graduated sizes; h1/h2 get a bottom border
//   - Paragraphs: comfortable spacing (mb-3) so text isn't cramped
//   - Lists: list-outside so bullets hang in the margin
//   - Inline code: subtle background + small horizontal padding
//   - Code blocks: panel with rounded corners, distinct background, language label
//   - Tables: bordered with alternating rows
//   - Blockquotes: left bar, dim text
//   - Links: accent color + underline
//   - Horizontal rules + GFM strikethrough + task-list checkboxes
export default function Markdown({ children, className = '' }: Props) {
  const { themeMode } = usePlatform()
  const isDark = themeMode === 'dark'

  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      className={`prose ${isDark ? 'prose-invert' : ''} prose-sm max-w-none ${className}`}
      components={{
        // Block-level
        p: ({ children }) => <p className="mb-3 last:mb-0 text-[15px] leading-relaxed text-ask-text">{children}</p>,
        h1: ({ children }) => <h1 className="text-[22px] font-semibold mt-4 mb-3 pb-1 border-b border-ask-sep text-ask-text first:mt-0">{children}</h1>,
        h2: ({ children }) => <h2 className="text-[18px] font-semibold mt-4 mb-2 pb-1 border-b border-ask-sep text-ask-text first:mt-0">{children}</h2>,
        h3: ({ children }) => <h3 className="text-[16px] font-semibold mt-3 mb-1.5 text-ask-text first:mt-0">{children}</h3>,
        h4: ({ children }) => <h4 className="text-[15px] font-semibold mt-3 mb-1 text-ask-text first:mt-0">{children}</h4>,
        h5: ({ children }) => <h5 className="text-[14px] font-semibold mt-2 mb-1 text-ask-text first:mt-0">{children}</h5>,
        h6: ({ children }) => <h6 className="text-[13px] font-semibold mt-2 mb-1 uppercase tracking-wide text-ask-secondary first:mt-0">{children}</h6>,
        ul: ({ children }) => <ul className="list-disc list-outside pl-5 mb-3 space-y-1 marker:text-ask-secondary">{children}</ul>,
        ol: ({ children }) => <ol className="list-decimal list-outside pl-5 mb-3 space-y-1 marker:text-ask-secondary">{children}</ol>,
        li: ({ children }) => <li className="text-[15px] leading-relaxed text-ask-text">{children}</li>,
        hr: () => <hr className="my-4 border-0 h-px bg-ask-sep" />,
        blockquote: ({ children }) => (
          <blockquote className="my-3 pl-3 border-l-[3px] border-ask-sep text-ask-secondary [&>p]:text-ask-secondary">{children}</blockquote>
        ),

        // Inline
        strong: ({ children }) => <strong className="font-semibold text-ask-text">{children}</strong>,
        em: ({ children }) => <em className="italic">{children}</em>,
        del: ({ children }) => <del className="text-ask-secondary line-through">{children}</del>,
        a: ({ children, href }) => (
          <a href={href} target="_blank" rel="noopener noreferrer" className="text-ask-blue underline underline-offset-2 hover:opacity-80">
            {children}
          </a>
        ),

        // Code: react-markdown calls `code` for both inline and block; only block has language-* className
        code: ({ children, className: codeClass }) => {
          const langMatch = /language-([^\s]+)/.exec(codeClass ?? '')
          const isBlock = !!langMatch
          if (!isBlock) {
            return (
              <code className="bg-ask-card2 rounded px-[0.35em] py-[0.15em] text-[0.875em] font-mono text-ask-text border border-ask-sep/60">
                {children}
              </code>
            )
          }
          return (
            <code className={`block font-mono text-[13px] leading-snug ${codeClass ?? ''}`}>
              {children}
            </code>
          )
        },
        pre: ({ children }) => {
          // Find the inner code element and pull its language for the label.
          // We're given `children` typed as ReactNode, so probe defensively.
          let lang = ''
          // @ts-expect-error — runtime shape
          const inner = children?.props?.className as string | undefined
          const m = /language-([^\s]+)/.exec(inner ?? '')
          if (m) lang = m[1]
          return (
            <div className="my-3 rounded-md overflow-hidden border border-ask-sep bg-ask-card2">
              {lang && (
                <div className="px-3 py-1 text-[11px] font-mono text-ask-secondary border-b border-ask-sep bg-ask-card2/60">
                  {lang}
                </div>
              )}
              <pre className="px-3 py-2 overflow-x-auto whitespace-pre text-ask-text">{children}</pre>
            </div>
          )
        },

        // Tables (GFM)
        table: ({ children }) => (
          <div className="my-3 overflow-x-auto rounded-md border border-ask-sep">
            <table className="w-full border-collapse text-[14px]">{children}</table>
          </div>
        ),
        thead: ({ children }) => <thead className="bg-ask-card2">{children}</thead>,
        tbody: ({ children }) => <tbody>{children}</tbody>,
        tr: ({ children }) => <tr className="border-b border-ask-sep last:border-b-0 even:bg-ask-card2/30">{children}</tr>,
        th: ({ children }) => <th className="px-3 py-1.5 text-left font-semibold text-ask-text">{children}</th>,
        td: ({ children }) => <td className="px-3 py-1.5 text-ask-text align-top">{children}</td>,

        // Task-list checkboxes (GFM `- [x]`)
        input: (props) => {
          if (props.type === 'checkbox') {
            return <input type="checkbox" disabled checked={props.checked} className="mr-1.5 align-middle accent-ask-blue" />
          }
          return <input {...props} />
        },
      }}
    >
      {children}
    </ReactMarkdown>
  )
}
