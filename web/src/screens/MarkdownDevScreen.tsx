import Markdown from '../components/shared/Markdown'

const SHOWCASE = `# H1 heading — top-level

Paragraph with **bold**, *italic*, ~~strike~~, \`inline code\`, and a [link](https://github.com).

## H2 heading

### H3 heading

#### H4 heading

##### H5 heading

###### H6 heading

Bulleted list:
- first item with **emphasis** on a word
- second item — long enough to wrap a couple of times so we can see how the bullet hangs in the margin instead of inline with the text. Lorem ipsum dolor sit amet.
- third item with \`inline code\` like \`function foo()\`

Numbered list:
1. one
2. two
3. three

Task list:
- [x] done item
- [ ] open item with \`code\`

> Blockquote: this is a quoted line, dimmer than body text and indented with a left border bar. Lorem ipsum dolor sit amet, consectetur adipiscing elit.

\`\`\`bash
$ echo "fenced code block — language label should appear above"
$ ls -la /tmp | head -3
$ git log --oneline -5
\`\`\`

\`\`\`python
def hello(name: str) -> str:
    return f"hi {name}"

class Greeter:
    def __init__(self, prefix: str):
        self.prefix = prefix
\`\`\`

| Column A | Column B | Column C |
|---|---|---|
| row 1 cell | yes | 1.0 |
| row 2 cell | no | 2.5 |
| row 3 cell with **bold** | maybe | 3.14 |
| row 4 cell with \`code\` | yes | 42 |

---

End of showcase.`

export default function MarkdownDevScreen() {
  return (
    <div className="px-4 py-4">
      <Markdown>{SHOWCASE}</Markdown>
    </div>
  )
}
